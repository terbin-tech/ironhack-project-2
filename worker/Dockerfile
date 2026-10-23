# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy the project file and restore dependencies
COPY Worker.csproj .
RUN dotnet restore

# Copy the rest of the source code and build
COPY . .
RUN dotnet publish -c Release -o /app/publish

# Stage 2: Runtime
FROM mcr.microsoft.com/dotnet/runtime:10.0 AS runtime
WORKDIR /app

# Copy the published output from the build stage
COPY --from=build /app/publish ./

# RDS CA bundle for TLS to Postgres (DB_SSL_ROOT_CERT). --chmod because ADD from a URL
# writes mode 600; the file sits directly in /usr/local/share because a
# directory BuildKit creates would get the same mode and the non-root user
# could not enter it.
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /usr/local/share/rds-global-bundle.pem

# Set environment variables (can be overridden at runtime)
ENV DB_HOST=db
ENV DB_USERNAME=postgres
ENV DB_NAME=postgres
ENV REDIS_HOST=redis

# app, the unprivileged user the .NET image ships
USER 1654

# Define the entry point
ENTRYPOINT ["dotnet", "Worker.dll"]
