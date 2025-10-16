#!/bin/sh
script_name="symfony-automations"

# Global configurations
: "${DISABLE_DEFAULT_CONFIG:=false}"
: "${APP_BASE_DIR:=/var/www/html}"
: "${AUTORUN_LIB_DIR:=/etc/entrypoint.d/lib}"

# Set default values for Symfony automations
: "${AUTORUN_ENABLED:=false}"
: "${AUTORUN_DEBUG:=false}"

# Set default values for cache management
: "${AUTORUN_SYMFONY_CACHE_CLEAR:=true}"
: "${AUTORUN_SYMFONY_CACHE_WARMUP:=true}"

# Set default values for migrations
: "${AUTORUN_SYMFONY_MIGRATION:=true}"
: "${AUTORUN_SYMFONY_MIGRATION_DATABASE:=}"
: "${AUTORUN_SYMFONY_MIGRATION_MODE:=default}"
: "${AUTORUN_SYMFONY_MIGRATION_TIMEOUT:=30}"
: "${AUTORUN_SYMFONY_MIGRATION_SKIP_DB_CHECK:=false}"
: "${AUTORUN_SYMFONY_DATABASE_CREATE:=true}"

# Set default values for fixtures
: "${AUTORUN_SYMFONY_FIXTURES:=false}"
: "${AUTORUN_SYMFONY_FIXTURES_PROVIDER:=doctrine}"
: "${AUTORUN_SYMFONY_FIXTURES_APPEND:=false}"

# Set default values for other automations
: "${AUTORUN_SYMFONY_ASSETS_INSTALL:=false}"
: "${AUTORUN_SYMFONY_SCHEMA_VALIDATE:=false}"
: "${AUTORUN_SYMFONY_MESSENGER_SETUP_TRANSPORTS:=false}"

# Set default values for Symfony version
INSTALLED_SYMFONY_VERSION=""

############################################################################
# Sanity Checks
############################################################################

debug_log() {
    if [ "$LOG_OUTPUT_LEVEL" = "debug" ] || [ "$AUTORUN_DEBUG" = "true" ]; then
        echo "👉 DEBUG ($script_name): $1" >&2
    fi
}

if [ "$DISABLE_DEFAULT_CONFIG" = "true" ] || [ "$AUTORUN_ENABLED" = "false" ]; then
    debug_log "Skipping Symfony automations because DISABLE_DEFAULT_CONFIG is true or AUTORUN_ENABLED is false."
    exit 0
fi

############################################################################
# Functions
############################################################################

is_sqlite_database() {
    connection_name="${1:-default}"

    # Check DATABASE_URL environment variable first (most common case)
    if [ -n "$DATABASE_URL" ]; then
        case "$DATABASE_URL" in
            sqlite:*|sqlite3:*)
                debug_log "Detected SQLite from DATABASE_URL"
                return 0  # Is SQLite
                ;;
        esac
    fi

    # If connection name is specified and not default, check for specific connection env var
    if [ "$connection_name" != "default" ] && [ -n "$connection_name" ]; then
        # Convert connection name to uppercase for env var (e.g., tenant -> TENANT_DATABASE_URL)
        connection_env_var="$(echo "$connection_name" | tr '[:lower:]' '[:upper:]')_DATABASE_URL"
        connection_url=$(eval echo \$$connection_env_var)

        if [ -n "$connection_url" ]; then
            case "$connection_url" in
                sqlite:*|sqlite3:*)
                    debug_log "Detected SQLite from $connection_env_var"
                    return 0  # Is SQLite
                    ;;
            esac
        fi
    fi

    # If we can't determine from env vars, check using PHP (lightweight, no full bootstrap)
    check_result=$(php -r "
        require '$APP_BASE_DIR/vendor/autoload.php';

        // Load .env file to get DATABASE_URL if not already in environment
        if (class_exists('\Symfony\Component\Dotenv\Dotenv')) {
            (new \Symfony\Component\Dotenv\Dotenv())->bootEnv('$APP_BASE_DIR/.env');
        }

        // Check DATABASE_URL for default connection
        if ('$connection_name' === 'default' || '$connection_name' === '') {
            \$dbUrl = \$_ENV['DATABASE_URL'] ?? \$_SERVER['DATABASE_URL'] ?? '';
            if (str_starts_with(\$dbUrl, 'sqlite:') || str_starts_with(\$dbUrl, 'sqlite3:')) {
                echo 'sqlite';
                exit(0);
            }
        } else {
            // Check for specific connection env var
            \$envVar = strtoupper('$connection_name') . '_DATABASE_URL';
            \$dbUrl = \$_ENV[\$envVar] ?? \$_SERVER[\$envVar] ?? '';
            if (str_starts_with(\$dbUrl, 'sqlite:') || str_starts_with(\$dbUrl, 'sqlite3:')) {
                echo 'sqlite';
                exit(0);
            }
        }
        exit(1);
    " 2>/dev/null)

    if [ "$check_result" = "sqlite" ]; then
        return 0  # Is SQLite
    else
        return 1  # Not SQLite
    fi
}

console_migrate() {
    debug_log "Starting migrations (mode: $AUTORUN_SYMFONY_MIGRATION_MODE)"

    # Clear cache before migrations
    if [ "$AUTORUN_SYMFONY_CACHE_CLEAR" = "true" ]; then
        echo "🚀 Clearing Symfony cache before attempting migrations..."
        php "$APP_BASE_DIR/bin/console" cache:clear --no-warmup
    fi

    # Determine if multiple databases are specified
    if [ -n "$AUTORUN_SYMFONY_MIGRATION_DATABASE" ]; then
        databases=$(convert_comma_delimited_to_space_separated "$AUTORUN_SYMFONY_MIGRATION_DATABASE")
        database_list=$(echo "$databases" | tr ',' ' ')

        for db in $database_list; do
            # Wait for this specific database to be ready
            if ! wait_for_database_connection "$db"; then
                echo "❌ $script_name: Failed to connect to database: $db"
                return 1
            fi

            # Create database if needed (skip for SQLite)
            if [ "$AUTORUN_SYMFONY_DATABASE_CREATE" = "true" ]; then
                if ! is_sqlite_database "$db"; then
                    echo "🚀 Creating database if it doesn't exist: $db"
                    php "$APP_BASE_DIR/bin/console" doctrine:database:create --if-not-exists --connection="$db" || true
                else
                    debug_log "Skipping database creation for SQLite connection: $db"
                fi
            fi

            # Run migrations based on mode
            run_migrations_for_connection "$db"
        done
    else
        # Wait for default database connection
        if ! wait_for_database_connection; then
            echo "❌ $script_name: Failed to connect to default database"
            return 1
        fi

        # Create database if needed (skip for SQLite)
        if [ "$AUTORUN_SYMFONY_DATABASE_CREATE" = "true" ]; then
            if ! is_sqlite_database ""; then
                echo "🚀 Creating database if it doesn't exist..."
                php "$APP_BASE_DIR/bin/console" doctrine:database:create --if-not-exists || true
            else
                debug_log "Skipping database creation for SQLite"
            fi
        fi

        # Run migrations with default database connection
        run_migrations_for_connection ""
    fi
}

run_migrations_for_connection() {
    connection_name="$1"
    connection_flag=""

    if [ -n "$connection_name" ]; then
        connection_flag="--em=$connection_name"
        echo "🚀 Running migrations for connection: $connection_name"
    fi

    # Handle different migration modes
    case "$AUTORUN_SYMFONY_MIGRATION_MODE" in
        "schema-reset")
            echo "🚀 Resetting database schema..."
            php "$APP_BASE_DIR/bin/console" doctrine:schema:drop --force --full-database $connection_flag
            php "$APP_BASE_DIR/bin/console" doctrine:schema:create $connection_flag
            echo "✅ Database schema reset complete."
            ;;
        "fresh")
            echo "🚀 Dropping and recreating database with migrations..."
            php "$APP_BASE_DIR/bin/console" doctrine:database:drop --force --if-exists $connection_flag
            php "$APP_BASE_DIR/bin/console" doctrine:database:create $connection_flag
            php "$APP_BASE_DIR/bin/console" doctrine:migrations:migrate --no-interaction --allow-no-migration $connection_flag
            echo "✅ Database fresh migration complete."
            ;;
        *)
            echo "🚀 Running migrations..."
            php "$APP_BASE_DIR/bin/console" doctrine:migrations:migrate --no-interaction --allow-no-migration $connection_flag
            ;;
    esac
}

console_fixtures() {
    fixture_provider="${AUTORUN_SYMFONY_FIXTURES_PROVIDER:=doctrine}"

    case "$fixture_provider" in
        "foundry")
            # Check if Foundry is available
            set +e
            php "$APP_BASE_DIR/bin/console" list foundry:load-fixtures > /dev/null 2>&1
            foundry_available=$?
            set -e

            if [ $foundry_available -eq 0 ]; then
                echo "🔧 Loading Foundry fixtures..."
                php "$APP_BASE_DIR/bin/console" foundry:load-fixtures --no-interaction
                echo "✅ Foundry fixtures loaded successfully."
            else
                echo "⚠️  Warning: Foundry fixtures requested but zenstruck/foundry is not installed or foundry:load-fixtures command not available."
                echo "    Install with: composer require zenstruck/foundry --dev"
                echo "    Falling back to Doctrine fixtures..."
                load_doctrine_fixtures
            fi
            ;;
        *)
            # Default: Doctrine fixtures
            load_doctrine_fixtures
            ;;
    esac
}

load_doctrine_fixtures() {
    echo "🔧 Loading Doctrine fixtures..."
    if [ "${AUTORUN_SYMFONY_FIXTURES_APPEND:=false}" = "true" ]; then
        php "$APP_BASE_DIR/bin/console" doctrine:fixtures:load --no-interaction --append
    else
        php "$APP_BASE_DIR/bin/console" doctrine:fixtures:load --no-interaction
    fi
    echo "✅ Doctrine fixtures loaded successfully."
}

console_cache_warmup() {
    echo "🚀 Warming up Symfony cache..."
    if ! php "$APP_BASE_DIR/bin/console" cache:warmup; then
        echo "❌ $script_name: Cache warmup failed"
        return 1
    fi
}

console_assets_install() {
    echo "🚀 Installing assets..."
    if ! php "$APP_BASE_DIR/bin/console" assets:install --no-interaction; then
        echo "❌ $script_name: Assets install failed"
        return 1
    fi
}

console_schema_validate() {
    echo "🔍 Validating Doctrine schema..."
    # Do not exit on error for validation
    set +e
    php "$APP_BASE_DIR/bin/console" doctrine:schema:validate
    validation_status=$?
    set -e

    if [ $validation_status -ne 0 ]; then
        echo "⚠️  Warning: Schema validation found issues. This is non-fatal in production."
    else
        echo "✅ Schema validation passed."
    fi
}

console_messenger_setup() {
    echo "🚀 Setting up Messenger transports..."
    if ! php "$APP_BASE_DIR/bin/console" messenger:setup-transports --no-interaction; then
        echo "❌ $script_name: Messenger setup failed"
        return 1
    fi
}

convert_comma_delimited_to_space_separated() {
    echo $1 | tr ',' ' '
}

get_symfony_version() {
    # Return cached version if already set
    if [ -n "$INSTALLED_SYMFONY_VERSION" ]; then
        debug_log "Using cached Symfony version: $INSTALLED_SYMFONY_VERSION"
        echo "$INSTALLED_SYMFONY_VERSION"
        return 0
    fi

    debug_log "Detecting Symfony version..."
    # Use 2>/dev/null to handle potential PHP warnings
    console_version_output=$(php "$APP_BASE_DIR/bin/console" --version 2>/dev/null)

    # Check if command was successful
    if [ $? -ne 0 ]; then
        echo "❌ $script_name: Failed to execute console command" >&2
        return 1
    fi

    # Extract version number using sed (POSIX compliant)
    # Pattern matches "Symfony X.Y.Z" or similar
    symfony_version=$(echo "$console_version_output" | sed -e 's/^Symfony \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*$/\1/')

    # Validate that we got a version number (POSIX compliant regex)
    if echo "$symfony_version" | grep '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null 2>&1; then
        INSTALLED_SYMFONY_VERSION="$symfony_version"
        debug_log "Detected Symfony version: $symfony_version"
        echo "$symfony_version"
        return 0
    else
        echo "❌ $script_name: Failed to determine Symfony version" >&2
        return 1
    fi
}

symfony_is_installed() {
    if [ ! -f "$APP_BASE_DIR/bin/console" ]; then
        return 1
    fi

    if [ ! -f "$APP_BASE_DIR/symfony.lock" ]; then
        return 1
    fi

    if [ ! -d "$APP_BASE_DIR/vendor" ]; then
        return 1
    fi

    return 0
}

symfony_version_is_at_least() {
    required_version="$1"

    if [ -z "$required_version" ]; then
        echo "❌ $script_name - Usage: symfony_version_is_at_least <required_version>" >&2
        return 1
    fi

    # Validate required version format
    if ! echo "$required_version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        echo "❌ $script_name - Invalid version requirement format: $required_version" >&2
        return 1
    fi

    current_version=$(get_symfony_version)
    if [ $? -ne 0 ]; then
        echo "❌ $script_name: Failed to get Symfony version" >&2
        return 1
    fi

    # normalize_version() takes a version string and ensures it has 3 parts
    normalize_version() {
        echo "$1" | awk -F. '{ print $1"."$2"."(NF>2?$3:0) }'
    }

    normalized_current=$(normalize_version "$current_version")
    normalized_required=$(normalize_version "$required_version")

    # Use sort -V to get the lower version, then compare it with required version
    lowest_version=$(printf '%s\n%s\n' "$normalized_required" "$normalized_current" | sort -V | head -n1)
    if [ "$lowest_version" = "$normalized_required" ]; then
        return 0    # Success: current version is >= required version
    else
        return 1    # Failure: current version is < required version
    fi
}

test_db_connection() {
    if [ "$AUTORUN_SYMFONY_MIGRATION_SKIP_DB_CHECK" = "true" ]; then
        return 0
    fi

    # Pass database connection name only if specified (not empty)
    database_arg="${1:-default}"
    php "$AUTORUN_LIB_DIR/symfony/test-db-connection.php" "$APP_BASE_DIR" "$AUTORUN_SYMFONY_MIGRATION_MODE" "$database_arg"
}

wait_for_database_connection() {
    database_name="${1:-default}"
    count=0
    timeout=$AUTORUN_SYMFONY_MIGRATION_TIMEOUT

    # Determine display name based on whether a specific connection was provided
    if [ "$database_name" = "default" ]; then
        display_name="default database"
        connection_label=""
    else
        display_name="database connection: $database_name"
        connection_label=": $database_name"
    fi

    debug_log "Waiting for connection to $display_name (timeout: ${timeout}s)"

    # Do not exit on error for this loop
    set +e
    echo "⚡️ Attempting connection to $display_name..."
    while [ $count -lt "$timeout" ]; do
        if [ "$AUTORUN_DEBUG" = "true" ]; then
            # Show output when debug is enabled
            test_db_connection "$database_name"
        else
            # Otherwise suppress output
            test_db_connection "$database_name" > /dev/null 2>&1
        fi
        status=$?
        if [ $status -eq 0 ]; then
            echo "✅ Database connection successful$connection_label"
            set -e
            return 0
        else
            # Only log every 5 attempts to reduce noise
            if [ $((count % 5)) -eq 0 ]; then
                debug_log "Connection attempt $((count + 1))/$timeout failed for $display_name (status: $status)"
            fi
            echo "Waiting on $display_name connection, retrying... $((timeout - count)) seconds left"
            count=$((count + 1))
            sleep 1
        fi
    done

    # Re-enable exit on error
    set -e

    echo "❌ $script_name: Database connection to $display_name failed after $timeout seconds."
    debug_log "Database connection timed out for $display_name after $timeout seconds"
    return 1
}

############################################################################
# Main
############################################################################

if symfony_is_installed; then
    if [ "$LOG_OUTPUT_LEVEL" = "debug" ] || [ "$AUTORUN_DEBUG" = "true" ]; then
        echo "Symfony detected: v$(get_symfony_version)"
        echo "Automation settings:"
        echo "--------------------------------"
        # Dynamically display all AUTORUN_* environment variables
        env | grep '^AUTORUN_' | sort | while IFS='=' read -r var_name var_value; do
            debug_log "- ${var_name}: ${var_value}"
        done
    fi

    echo "🤔 Checking for Symfony automations..."

    if [ "$AUTORUN_SYMFONY_MIGRATION" = "true" ]; then
        console_migrate
    fi

    if [ "$AUTORUN_SYMFONY_FIXTURES" = "true" ]; then
        console_fixtures
    fi

    if [ "$AUTORUN_SYMFONY_CACHE_WARMUP" = "true" ]; then
        console_cache_warmup
    fi

    if [ "$AUTORUN_SYMFONY_ASSETS_INSTALL" = "true" ]; then
        console_assets_install
    fi

    if [ "$AUTORUN_SYMFONY_SCHEMA_VALIDATE" = "true" ]; then
        console_schema_validate
    fi

    if [ "$AUTORUN_SYMFONY_MESSENGER_SETUP_TRANSPORTS" = "true" ]; then
        console_messenger_setup
    fi
else
    if [ "$LOG_OUTPUT_LEVEL" = "debug" ] || [ "$LOG_OUTPUT_LEVEL" = "info" ]; then
        echo "ℹ️  $script_name: Symfony not detected or AUTORUN_ENABLED is not set to 'true'. Skipping Symfony automations."
    fi
fi
