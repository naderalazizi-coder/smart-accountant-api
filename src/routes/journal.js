const express = require("express");
const { body, validationResult } = require("express-validator");
const { withTenant } = require("../db/pool");
const { requireAuth } = require("../middleware/auth");

const router = express.Router();
router.use(requireAuth);

/** GET /api/journal-entries — list this tenant's journal entries. */
router.get("/", async (req, res) => {
  const rows = await withTenant(req.auth.tenantId, (client) =>
    client.query(
      `SELECT id, entry_no, entry_date, memo, memo_ar, status, source_module, is_ai_generated, created_at
         FROM journal_entries
        WHERE tenant_id = $1
        ORDER BY entry_date DESC, created_at DESC
        LIMIT 100`,
      [req.auth.tenantId]
    )
  );
  res.json({ entries: rows.rows });
});

/** GET /api/journal-entries/:id — entry with its lines. */
router.get("/:id", async (req, res) => {
  const result = await withTenant(req.auth.tenantId, async (client) => {
    const entry = await client.query(`SELECT * FROM journal_entries WHERE id = $1 AND tenant_id = $2`, [req.params.id, req.auth.tenantId]);
    if (entry.rowCount === 0) return null;
    const lines = await client.query(
      `SELECT jel.*, coa.code AS account_code, coa.name AS account_name
         FROM journal_entry_lines jel
         JOIN chart_of_accounts coa ON coa.id = jel.account_id
        WHERE jel.journal_entry_id = $1 ORDER BY jel.line_no`,
      [req.params.id]
    );
    return { entry: entry.rows[0], lines: lines.rows };
  });
  if (!result) return res.status(404).json({ error: "not_found" });
  res.json(result);
});

/**
 * POST /api/journal-entries
 * Creates a draft, balanced, double-entry journal entry. Body:
 * { entryDate, memo, lines: [{ accountId, debit, credit, currencyCode, description }] }
 * Rejects unbalanced entries before touching the database — the DB
 * trigger is the backstop, this is the friendly first line of defense.
 */
router.post(
  "/",
  [
    body("entryDate").isISO8601(),
    body("lines").isArray({ min: 2 }).withMessage("A journal entry needs at least two lines."),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) return res.status(422).json({ error: "validation_error", details: errors.array() });

    const { entryDate, memo, memoAr, lines, sourceModule } = req.body;
    const totalDebit = lines.reduce((s, l) => s + Number(l.debit || 0), 0);
    const totalCredit = lines.reduce((s, l) => s + Number(l.credit || 0), 0);
    if (Math.abs(totalDebit - totalCredit) > 0.001) {
      return res.status(422).json({
        error: "unbalanced_entry",
        message: `Debits (${totalDebit}) must equal credits (${totalCredit}).`,
      });
    }

    try {
      const result = await withTenant(req.auth.tenantId, async (client) => {
        const period = await client.query(
          `SELECT p.id FROM accounting_periods p JOIN fiscal_years fy ON fy.id = p.fiscal_year_id
            WHERE fy.tenant_id = $1 AND $2::date BETWEEN p.start_date AND p.end_date`,
          [req.auth.tenantId, entryDate]
        );
        if (period.rowCount === 0) {
          throw Object.assign(new Error("no_period"), { code: "NO_PERIOD" });
        }

        const countRes = await client.query(`SELECT COUNT(*)::int AS n FROM journal_entries WHERE tenant_id = $1`, [req.auth.tenantId]);
        const entryNo = `JE-${new Date(entryDate).getFullYear()}-${String(countRes.rows[0].n + 1).padStart(6, "0")}`;

        const entryRes = await client.query(
          `INSERT INTO journal_entries (tenant_id, period_id, entry_no, entry_date, memo, memo_ar, source_module, created_by)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING id, entry_no, status`,
          [req.auth.tenantId, period.rows[0].id, entryNo, entryDate, memo || null, memoAr || null, sourceModule || "manual", req.auth.userId]
        );
        const entry = entryRes.rows[0];

        let lineNo = 1;
        for (const line of lines) {
          await client.query(
            `INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit, currency_code, description, line_no)
             VALUES ($1,$2,$3,$4,$5,$6,$7)`,
            [entry.id, line.accountId, line.debit || 0, line.credit || 0, line.currencyCode || "USD", line.description || null, lineNo++]
          );
        }
        return entry;
      });
      res.status(201).json({ entry: result });
    } catch (err) {
      if (err.code === "NO_PERIOD") {
        return res.status(422).json({
          error: "no_accounting_period",
          message: "No accounting period covers this date. Call POST /api/periods/bootstrap first.",
        });
      }
      console.error("create_journal_entry_error", err);
      res.status(500).json({ error: "failed_to_create_entry" });
    }
  }
);

/** POST /api/journal-entries/:id/post — posts a draft entry (DB trigger enforces balance). */
router.post("/:id/post", async (req, res) => {
  try {
    const result = await withTenant(req.auth.tenantId, (client) =>
      client.query(
        `UPDATE journal_entries SET status = 'posted', posted_by = $1
          WHERE id = $2 AND tenant_id = $3 AND status = 'draft'
          RETURNING id, entry_no, status, posted_at`,
        [req.auth.userId, req.params.id, req.auth.tenantId]
      )
    );
    if (result.rowCount === 0) {
      return res.status(404).json({ error: "not_found_or_not_draft" });
    }
    res.json({ entry: result.rows[0] });
  } catch (err) {
    console.error("post_journal_entry_error", err);
    res.status(400).json({ error: "post_failed", message: err.message });
  }
});

module.exports = router;
