<?php
/**
 * Test Symfony Database Connection
 *
 * This script tests if the Symfony application can connect to its configured database.
 * It's designed to be called from shell scripts during container initialization.
 *
 * Usage: php test-db-connection.php /path/to/app/base/dir [migration_mode] [database_connection]
 *
 * Arguments:
 *   app_base_dir        - Path to Symfony application root
 *   migration_mode      - Migration mode: 'default', 'schema-reset', or 'fresh' (optional, defaults to 'default')
 *   database_connection - Name of the database connection to test (optional, defaults to 'default')
 *
 * Exit codes:
 *   0 - Success: Database is ready and accessible
 *   1 - Failure: Database connection failed or other error
 *
 * @package serversideup/php
 */

// Validate arguments
if ($argc < 2 || $argc > 4) {
    fwrite(STDERR, "Usage: php test-db-connection.php /path/to/app/base/dir [migration_mode] [database_connection]\n");
    exit(1);
}

$appBaseDir = $argv[1];
$migrationMode = $argc >= 3 ? $argv[2] : 'default';
$databaseConnection = $argc >= 4 ? $argv[3] : 'default';

// Validate migration mode
$validModes = ['default', 'schema-reset', 'fresh'];
if (!in_array($migrationMode, $validModes)) {
    fwrite(STDERR, "Error: Invalid migration mode '{$migrationMode}'. Must be one of: " . implode(', ', $validModes) . "\n");
    exit(1);
}

// Validate that the app base directory exists
if (!is_dir($appBaseDir)) {
    fwrite(STDERR, "Error: App base directory does not exist: {$appBaseDir}\n");
    exit(1);
}

// Validate that required Symfony files exist
$vendorAutoload = "{$appBaseDir}/vendor/autoload.php";
$kernelFile = "{$appBaseDir}/src/Kernel.php";

if (!file_exists($vendorAutoload)) {
    fwrite(STDERR, "Error: Composer autoload file not found: {$vendorAutoload}\n");
    exit(1);
}

if (!file_exists($kernelFile)) {
    fwrite(STDERR, "Error: Symfony kernel file not found: {$kernelFile}\n");
    exit(1);
}

// Bootstrap Symfony
try {
    require $vendorAutoload;

    (new \Symfony\Component\Dotenv\Dotenv())->bootEnv($appBaseDir.'/.env');
    $kernel = new \App\Kernel($_SERVER['APP_ENV'] ?? 'prod', (bool) ($_SERVER['APP_DEBUG'] ?? false));
    $kernel->boot();
    $container = $kernel->getContainer();

} catch (Exception $e) {
    fwrite(STDERR, "Error bootstrapping Symfony: {$e->getMessage()}\n");
    exit(1);
}

// Test database connection
try {
    // Get Doctrine connection
    $doctrine = $container->get('doctrine');
    $connection = $doctrine->getConnection($databaseConnection);

    // Get platform info
    $platform = $connection->getDatabasePlatform();
    $driver = $platform->getName();

    // SQLite special handling
    if ($driver === 'sqlite') {
        $params = $connection->getParams();
        $dbPath = $params['path'] ?? null;

        // Handle in-memory SQLite databases
        if ($dbPath === ':memory:' || empty($dbPath)) {
            fwrite(STDOUT, "SQLite in-memory database detected - ready\n");
            exit(0);
        }

        $dbDirectory = dirname($dbPath);

        // Check if database file already exists
        if (file_exists($dbPath)) {
            fwrite(STDOUT, "SQLite database file exists: {$dbPath}\n");
            exit(0);
        }

        // Database file doesn't exist - check if directory exists and is writable
        if (!is_dir($dbDirectory)) {
            fwrite(STDERR, "SQLite database directory does not exist: {$dbDirectory}\n");
            fwrite(STDERR, "Please create the directory before running migrations.\n");
            fwrite(STDERR, "Example: mkdir -p {$dbDirectory}\n");
            exit(1);
        }

        if (!is_writable($dbDirectory)) {
            fwrite(STDERR, "SQLite database directory is not writable: {$dbDirectory}\n");
            fwrite(STDERR, "Please check directory permissions.\n");
            exit(1);
        }

        // For 'schema-reset' and 'fresh' modes, the database file must already exist
        if ($migrationMode === 'schema-reset' || $migrationMode === 'fresh') {
            fwrite(STDERR, "SQLite database file does not exist: {$dbPath}\n");
            fwrite(STDERR, "Migration mode '{$migrationMode}' requires the database file to exist.\n");
            fwrite(STDERR, "Either:\n");
            fwrite(STDERR, "  1. Create the database (ensure it has read and write permissions for your user): touch {$dbPath}\n");
            fwrite(STDERR, "  2. Use AUTORUN_SYMFONY_MIGRATION_MODE=default to let Doctrine create it\n");
            exit(1);
        }

        // Directory exists and is writable - migrations can create the database file (default mode only)
        fwrite(STDOUT, "SQLite database directory is ready - migrations will create database\n");
        exit(0);
    }

    // Test connection for other database drivers
    $connection->connect();

    if ($connection->isConnected()) {
        $connectionName = $databaseConnection !== 'default' ? " ({$databaseConnection})" : '';
        fwrite(STDOUT, "Database connection successful ({$driver}){$connectionName}\n");
        exit(0);
    } else {
        fwrite(STDERR, "Database connection failed\n");
        exit(1);
    }

} catch (Exception $e) {
    $connectionName = $databaseConnection !== 'default' ? " ({$databaseConnection})" : '';
    fwrite(STDERR, "Database connection error{$connectionName}: {$e->getMessage()}\n");
    exit(1);
}
