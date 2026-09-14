using AccessApp.Data;
using AccessApp.Repositories;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ISqliteConnectionFactory, SqliteConnectionFactory>();
builder.Services.AddScoped<IBookingRepository, SqliteBookingRepository>();
builder.Services.AddScoped<DatabaseInitializer>();

var app = builder.Build();

// A database or file-system problem should be visible in the logs, but must not
// prevent App Service from starting and serving its diagnostic/error pages.
try
{
    await using var scope = app.Services.CreateAsyncScope();
    var initializer = scope.ServiceProvider.GetRequiredService<DatabaseInitializer>();
    await initializer.InitializeAsync();
}
catch (Exception exception)
{
    app.Logger.LogError(exception, "Database initialization or seeding failed. The application will continue to start.");
}

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.UseAuthorization();
app.MapRazorPages();

await app.RunAsync();

public partial class Program;
