using Microsoft.Data.Sqlite;

namespace AccessApp.Data;

public interface ISqliteConnectionFactory
{
    Task<SqliteConnection> OpenConnectionAsync(CancellationToken cancellationToken = default);
}
