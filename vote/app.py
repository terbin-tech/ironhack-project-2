from flask import Flask, render_template, request, make_response, g
from redis import Redis
from redis.backoff import NoBackoff
from redis.retry import Retry
import os
import socket
import random
import json
import logging

# Read options and Redis configuration from environment variables
option_a = os.getenv('OPTION_A', "Cats")
option_b = os.getenv('OPTION_B', "Dogs")
voting_mode = os.getenv('VOTING_MODE') or 'every-click'
if voting_mode not in ('every-click', 'one-per-voter'):
    raise ValueError(f"VOTING_MODE must be 'every-click' or 'one-per-voter', got '{voting_mode}'")
redis_host = os.getenv('REDIS_HOST', 'redis')  # Default to 'redis' for compatibility
redis_port = int(os.getenv('REDIS_PORT', 6379))  # Default Redis port is 6379
redis_tls = os.getenv('REDIS_TLS', '').lower() == 'true'  # true: TLS, verified against the system CA store
hostname = socket.gethostname()

# Serve static files under /vote, so an Ingress that routes only /vote to this app still reaches them
app = Flask(__name__, static_url_path='/vote/static')

gunicorn_error_logger = logging.getLogger('gunicorn.error')
app.logger.handlers.extend(gunicorn_error_logger.handlers)
app.logger.setLevel(logging.INFO)

def read_setting(name):
    # A value from the file named by <name>_FILE when set (read per request, so a
    # rotated secret is picked up), else from <name>; None when neither is set.
    path = os.getenv(name + '_FILE')
    if path:
        with open(path) as f:
            return f.read().strip()
    return os.getenv(name)

def get_redis():
    if not hasattr(g, 'redis'):
        # Fail fast: one attempt of at most 2 seconds (the connect timeout follows
        # socket_timeout). redis-py retries 10 times by default, so during a Valkey
        # failover each vote would hold a gunicorn worker long enough to block the
        # page loads and health checks the same workers serve.
        # Without a username and password redis-py sends no AUTH (Compose's plain
        # Redis). driver_info=None skips CLIENT SETINFO, which vote's Valkey user
        # may not run.
        g.redis = Redis(host=redis_host, port=redis_port, db=0, socket_timeout=2,
                        retry=Retry(NoBackoff(), 0), ssl=redis_tls,
                        username=read_setting('REDIS_USERNAME'),
                        password=read_setting('REDIS_PASSWORD'),
                        driver_info=None)
    return g.redis

@app.route("/", methods=['POST','GET'])
@app.route("/vote", methods=['POST','GET'])
def hello():
    voter_id = request.cookies.get('voter_id')
    if not voter_id:
        voter_id = hex(random.getrandbits(64))[2:-1]

    vote = None

    if request.method == 'POST':
        redis = get_redis()
        vote = request.form['vote']
        app.logger.info('Received vote for %s', vote)
        data = json.dumps({'voter_id': voter_id, 'vote': vote})
        redis.rpush('votes', data)

    resp = make_response(render_template(
        'index.html',
        option_a=option_a,
        option_b=option_b,
        hostname=hostname,
        vote=vote,
        one_per_voter=(voting_mode == 'one-per-voter'),
    ))
    resp.set_cookie('voter_id', voter_id)
    return resp


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=os.getenv('PORT', 80), debug=True, threaded=True)
