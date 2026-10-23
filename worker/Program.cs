using System;
using System.Data;
using System.Data.Common;
using System.Net.Sockets;
using System.Threading;
using Newtonsoft.Json;
using Npgsql;
using StackExchange.Redis;

namespace Worker
{
    public class Program
    {
        private const int MaxStrikes = 3;
        private const long HeartbeatIntervalMs = 5000;

        // Null until the first write, so the first Heartbeat call always writes
        private static long? lastHeartbeat;

        public static int Main(string[] args)
        {
            try
            {
                // Fetch configuration from environment variables
                var dbHost = Environment.GetEnvironmentVariable("DB_HOST") ?? "db";
                var dbName = Environment.GetEnvironmentVariable("DB_NAME") ?? "postgres";
                
                var redisHost = Environment.GetEnvironmentVariable("REDIS_HOST") ?? "redis";
                var redisPort = Environment.GetEnvironmentVariable("REDIS_PORT") ?? "6379";
                var redisTls = Environment.GetEnvironmentVariable("REDIS_TLS") == "true";
                var votingMode = Environment.GetEnvironmentVariable("VOTING_MODE");
                if (string.IsNullOrEmpty(votingMode))
                {
                    votingMode = "every-click";
                }
                if (votingMode != "every-click" && votingMode != "one-per-voter")
                {
                    Console.Error.WriteLine($"VOTING_MODE must be 'every-click' or 'one-per-voter', got '{votingMode}'");
                    return 1;
                }

                var dbTls = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DB_SSL_ROOT_CERT"));
                Console.WriteLine($"Connecting to db: host={dbHost} database={dbName} tls={(dbTls ? "on" : "off")}");

                // The Postgres connection string is built per attempt (see BuildPgConnectionString)
                var redisConfiguration = $"{redisHost}:{redisPort}" + (redisTls ? ",ssl=true,checkCertificateRevocation=false" : "");
                Console.WriteLine($"Connecting to redis: host={redisHost} port={redisPort} tls={(redisTls ? "on" : "off")}");

                NpgsqlConnection? pgsql = null;
                ConnectionMultiplexer? redisConn = null;
                IDatabase? redis = null;
                var dbStale = true;
                var redisStale = true;
                string? pendingPushBack = null;
                string? lastFailedVote = null;
                var strikes = 0;

                var definition = new { vote = "", voter_id = "" };
                while (true)
                {
                    Heartbeat();

                    // Slow down to prevent CPU spike, only query each 100ms
                    Thread.Sleep(100);

                    // Open or reopen what the last failure marked stale, put a vote that
                    // could not be stored back in the queue, then take the next vote.
                    // A failure here is a failure of the service the stage talks to.
                    var stage = "redis";
                    string? json;
                    try
                    {
                        if (redisStale)
                        {
                            DisposeQuietly(redisConn);
                            redisConn = OpenRedisConnection(redisConfiguration);
                            redis = redisConn.GetDatabase();
                            redisStale = false;
                        }
                        if (pendingPushBack != null)
                        {
                            redis!.ListLeftPush("votes", pendingPushBack);
                            pendingPushBack = null;
                        }

                        stage = "db";
                        if (dbStale || pgsql == null || pgsql.State != ConnectionState.Open)
                        {
                            DisposeQuietly(pgsql);
                            pgsql = OpenDbConnection(dbHost, dbName);
                            dbStale = false;
                        }

                        stage = "redis";
                        json = redis!.ListLeftPop("votes");
                    }
                    catch (Exception ex)
                    {
                        if (stage == "db")
                        {
                            dbStale = true;
                            Console.WriteLine("Reconnecting DB");
                        }
                        else
                        {
                            redisStale = true;
                            Console.WriteLine("Reconnecting Redis");
                        }
                        Console.Error.WriteLine($"{stage} failed: {ex.GetType().Name}: {ex.Message}");
                        Thread.Sleep(1000);
                        continue;
                    }

                    if (json == null)
                    {
                        try
                        {
                            using var keepAlive = pgsql!.CreateCommand();
                            keepAlive.CommandText = "SELECT 1";
                            keepAlive.ExecuteNonQuery();
                        }
                        catch (Exception ex)
                        {
                            dbStale = true;
                            Console.WriteLine("Reconnecting DB");
                            Console.Error.WriteLine($"Keep-alive failed: {ex.GetType().Name}: {ex.Message}");
                            Thread.Sleep(1000);
                        }
                        continue;
                    }

                    var vote = JsonConvert.DeserializeAnonymousType(json, definition);
                    Console.WriteLine($"Processing vote for '{vote.vote}' by '{vote.voter_id}'");

                    try
                    {
                        if (votingMode == "one-per-voter")
                        {
                            ReplaceVote(pgsql!, vote.voter_id, vote.vote);
                        }
                        else
                        {
                            UpdateVote(pgsql!, vote.voter_id, vote.vote);
                        }
                        lastFailedVote = null;
                        strikes = 0;
                    }
                    catch (PostgresException ex) when (IsBadData(ex))
                    {
                        // Postgres refused the vote itself, so retrying cannot help
                        Console.Error.WriteLine($"Dropping vote by '{vote.voter_id}': {ex.SqlState} {ex.Message}");
                        lastFailedVote = null;
                        strikes = 0;
                    }
                    catch (Exception ex)
                    {
                        // The connection is the likely cause. Put the vote back and reconnect,
                        // but give up on a vote that fails MaxStrikes times in a row.
                        strikes = json == lastFailedVote ? strikes + 1 : 1;
                        lastFailedVote = json;
                        dbStale = true;
                        Console.WriteLine("Reconnecting DB");
                        Console.Error.WriteLine($"Storing vote failed ({strikes} of {MaxStrikes}): {ex.GetType().Name}: {ex.Message}");
                        if (strikes >= MaxStrikes)
                        {
                            Console.Error.WriteLine($"Dropping vote by '{vote.voter_id}' after {MaxStrikes} failures");
                            lastFailedVote = null;
                            strikes = 0;
                        }
                        else
                        {
                            pendingPushBack = json;
                        }
                        Thread.Sleep(1000);
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
        }

        // A value from the file named by <name>_FILE when set (read now, so a rotated
        // secret is picked up), else from <name>, else the fallback.
        private static string ReadSetting(string name, string fallback)
        {
            var file = Environment.GetEnvironmentVariable(name + "_FILE");
            if (!string.IsNullOrEmpty(file))
            {
                return File.ReadAllText(file).Trim();
            }
            return Environment.GetEnvironmentVariable(name) ?? fallback;
        }

        private static string BuildPgConnectionString(string dbHost, string dbName)
        {
            var builder = new NpgsqlConnectionStringBuilder
            {
                Host = dbHost,
                Username = ReadSetting("DB_USERNAME", "postgres"),
                Password = ReadSetting("DB_PASSWORD", "postgres"),
                Database = dbName,
                Timeout = 5,
                CommandTimeout = 10,
                GssEncryptionMode = GssEncryptionMode.Disable
            };
            var rootCert = Environment.GetEnvironmentVariable("DB_SSL_ROOT_CERT");
            if (!string.IsNullOrEmpty(rootCert))
            {
                builder.SslMode = SslMode.VerifyFull;
                builder.RootCertificate = rootCert;
            }
            return builder.ConnectionString;
        }

        private static NpgsqlConnection OpenDbConnection(string dbHost, string dbName)
        {
            NpgsqlConnection connection;

            while (true)
            {
                Heartbeat();
                try
                {
                    connection = new NpgsqlConnection(BuildPgConnectionString(dbHost, dbName));
                    connection.Open();
                    break;
                }
                catch (Exception ex) when (ex is SocketException || ex is DbException)
                {
                    Console.Error.WriteLine($"Waiting for db: {ex.Message}");
                    Thread.Sleep(1000);
                }
            }

            Console.Error.WriteLine("Connected to db");

            try
            {
                var command = connection.CreateCommand();
                command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                            id VARCHAR(255) NOT NULL,
                                            vote VARCHAR(255) NOT NULL
                                        )";
                command.ExecuteNonQuery();
            }
            catch
            {
                connection.Dispose();
                throw;
            }

            return connection;
        }

        private static ConnectionMultiplexer OpenRedisConnection(string configuration)
        {
            while (true)
            {
                Heartbeat();
                try
                {
                    Console.Error.WriteLine("Connecting to redis");
                    return ConnectionMultiplexer.Connect(configuration);
                }
                catch (Exception ex) when (ex is RedisConnectionException || ex is SocketException || ex is InvalidOperationException)
                {
                    Console.Error.WriteLine($"Waiting for redis: {ex.Message}");
                    Thread.Sleep(1000);
                }
            }
        }

        // Touches the file the container probes check. A failed write must not stop vote
        // processing (the probe then restarts the pod), so the failure is only logged, and
        // the timer advances anyway so a broken write is retried every interval, not on every loop.
        private static void Heartbeat()
        {
            var now = Environment.TickCount64;
            if (lastHeartbeat is long last && now - last < HeartbeatIntervalMs)
            {
                return;
            }
            lastHeartbeat = now;
            try
            {
                File.WriteAllBytes("/tmp/heartbeat", Array.Empty<byte>());
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Heartbeat write failed: {ex.GetType().Name}: {ex.Message}");
            }
        }

        // Class 22 (data exception) and 23 (integrity violation): the vote itself is bad
        private static bool IsBadData(PostgresException ex)
            => ex.SqlState.StartsWith("22", StringComparison.Ordinal) || ex.SqlState.StartsWith("23", StringComparison.Ordinal);

        private static void DisposeQuietly(IDisposable? resource)
        {
            try
            {
                resource?.Dispose();
            }
            catch (Exception)
            {
            }
        }

        private static void UpdateVote(NpgsqlConnection connection, string voterId, string vote)
        {
            var command = connection.CreateCommand();
            try
            {
                command.CommandText = "INSERT INTO votes (id, vote) VALUES (@id, @vote)";
                command.Parameters.AddWithValue("@id", voterId);
                command.Parameters.AddWithValue("@vote", vote);
                command.ExecuteNonQuery();
            }
            catch (DbException)
            {
                command.CommandText = "UPDATE votes SET vote = @vote WHERE id = @id";
                // No row to update means the vote was not stored: let the caller see the original error
                if (command.ExecuteNonQuery() == 0) throw;
            }
            finally
            {
                command.Dispose();
            }
        }

        private static void ReplaceVote(NpgsqlConnection connection, string voterId, string vote)
        {
            using var transaction = connection.BeginTransaction();

            using (var delete = connection.CreateCommand())
            {
                delete.Transaction = transaction;
                delete.CommandText = "DELETE FROM votes WHERE id = @id";
                delete.Parameters.AddWithValue("@id", voterId);
                delete.ExecuteNonQuery();
            }

            using (var insert = connection.CreateCommand())
            {
                insert.Transaction = transaction;
                insert.CommandText = "INSERT INTO votes (id, vote) VALUES (@id, @vote)";
                insert.Parameters.AddWithValue("@id", voterId);
                insert.Parameters.AddWithValue("@vote", vote);
                insert.ExecuteNonQuery();
            }

            transaction.Commit();
        }
    }
}
