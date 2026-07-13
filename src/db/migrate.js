const fs = require("fs");
const path = require("path");
const { pool } = require("./pool");

async function migrate() {
  const check = await pool.query(
    `SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'tenants') AS exists`
  );
  if (check.rows[0].exists) {
    console.log("Database already initialized — skipping migration.");
    return;
  }

  console.log("Empty database detected — applying schema.sql ...");
  const schemaSql = fs.readFileSync(path.join(__dirname, "..", "..", "schema.sql"), "utf8");
  await pool.query(schemaSql);

  console.log("Applying seed.sql (currencies reference data only, no company data) ...");
  const seedSql = fs.readFileSync(path.join(__dirname, "..", "..", "seed.sql"), "utf8");
  await pool.query(seedSql);

  console.log("Migration complete. Database is empty and ready for real signups.");
}

module.exports = { migrate };
