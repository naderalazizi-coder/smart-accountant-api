const express = require("express");
const { withTenant } = require("../db/pool");
const { requireAuth } = require("../middleware/auth");

const router = express.Router();
router.use(requireAuth);

/** GET /api/periods — list fiscal years + periods for this tenant. */
router.get("/", async (req, res) => {
  const rows = await withTenant(req.auth.tenantId, (client) =>
    client.query(
      `SELECT p.id, p.period_no, p.start_date, p.end_date, p.is_closed, fy.name AS fiscal_year
         FROM accounting_periods p
         JOIN fiscal_years fy ON fy.id = p.fiscal_year_id
        WHERE fy.tenant_id = $1
        ORDER BY p.start_date`,
      [req.auth.tenantId]
    )
  );
  res.json({ periods: rows.rows });
});

/**
 * POST /api/periods/bootstrap
 * Creates a fiscal year (Jan–Dec of the given year, default = current
 * year) with its 12 monthly periods. A new tenant has no calendar until
 * this is called — kept as an explicit, empty-by-default step rather
 * than something seeded automatically at signup.
 */
router.post("/bootstrap", async (req, res) => {
  const year = Number(req.body.year) || new Date().getFullYear();
  try {
    const result = await withTenant(req.auth.tenantId, async (client) => {
      const existing = await client.query(
        `SELECT id FROM fiscal_years WHERE tenant_id = $1 AND name = $2`,
        [req.auth.tenantId, `FY${year}`]
      );
      if (existing.rowCount > 0) {
        return { alreadyExists: true, fiscalYearId: existing.rows[0].id };
      }

      const fyRes = await client.query(
        `INSERT INTO fiscal_years (tenant_id, name, start_date, end_date)
         VALUES ($1, $2, $3, $4) RETURNING id`,
        [req.auth.tenantId, `FY${year}`, `${year}-01-01`, `${year}-12-31`]
      );
      const fiscalYearId = fyRes.rows[0].id;

      for (let m = 1; m <= 12; m++) {
        const start = new Date(Date.UTC(year, m - 1, 1));
        const end = new Date(Date.UTC(year, m, 0));
        await client.query(
          `INSERT INTO accounting_periods (tenant_id, fiscal_year_id, period_no, start_date, end_date)
           VALUES ($1,$2,$3,$4,$5)`,
          [req.auth.tenantId, fiscalYearId, m, start.toISOString().slice(0, 10), end.toISOString().slice(0, 10)]
        );
      }
      return { alreadyExists: false, fiscalYearId };
    });
    res.status(result.alreadyExists ? 200 : 201).json({ fiscalYear: `FY${year}`, ...result });
  } catch (err) {
    console.error("bootstrap_periods_error", err);
    res.status(500).json({ error: "failed_to_bootstrap_periods" });
  }
});

module.exports = router;
