const { Pool } = require("pg");

// Managed hosts (Railway, Render, etc.) provide a single DATABASE_URL.
// Local/docker-compose use separate DB_HOST/DB_USER/... vars instead.
const pool = process.env.DATABASE_URL
  ? new Pool({
      connectionString: process.env.DATABASE_URL,
      ssl: process.env.DB_SSL === "false" ? false : { rejectUnauthorized: false },
    })
  : new Pool({
      host: process.env.DB_HOST || "localhost",
      port: process.env.DB_PORT || 5432,
      user: process.env.DB_USER || "postgres",
      password: process.env.DB_PASSWORD || "postgres",
      database: process.env.DB_NAME || "smart_accountant",
    });

/**
 * Runs `fn` inside a transaction with app.current_tenant_id set for the
 * connection, so every Row-Level Security policy in the schema scopes
 * queries to that tenant automatically. This is the ONLY way route
 * handlers should touch tenant-scoped tables — it makes cross-tenant
 * data leaks a database-level impossibility, not just an app-level rule.
 */
async function withTenant(tenantId, fn) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    if (tenantId) {
      await client.query("SELECT set_config('app.current_tenant_id', $1, true)", [tenantId]);
    }
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

/** For operations that must run before a tenant exists (e.g. signup itself). */
async function withoutTenant(fn) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, withTenant, withoutTenant };
