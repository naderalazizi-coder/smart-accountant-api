const express = require("express");
const { body, validationResult } = require("express-validator");
const { withTenant } = require("../db/pool");
const { requireAuth } = require("../middleware/auth");

const router = express.Router();
router.use(requireAuth);

/** GET /api/accounts — list this tenant's chart of accounts (empty for a new company). */
router.get("/", async (req, res) => {
  try {
    const rows = await withTenant(req.auth.tenantId, (client) =>
      client.query(
        `SELECT id, code, name, name_ar, account_type, currency_code, is_control_account,
                is_active, opening_balance, parent_id
           FROM chart_of_accounts
          WHERE tenant_id = $1
          ORDER BY code`,
        [req.auth.tenantId]
      )
    );
    res.json({ accounts: rows.rows });
  } catch (err) {
    console.error("list_accounts_error", err);
    res.status(500).json({ error: "failed_to_list_accounts" });
  }
});

/** POST /api/accounts — create a new GL account for this tenant. */
router.post(
  "/",
  [
    body("code").trim().notEmpty(),
    body("name").trim().notEmpty(),
    body("accountType").isIn(["asset", "liability", "equity", "revenue", "expense"]),
    body("currencyCode").isLength({ min: 3, max: 3 }),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) return res.status(422).json({ error: "validation_error", details: errors.array() });

    const { code, name, nameAr, accountType, currencyCode, parentId, isControlAccount, openingBalance } = req.body;
    try {
      const result = await withTenant(req.auth.tenantId, (client) =>
        client.query(
          `INSERT INTO chart_of_accounts
             (tenant_id, parent_id, code, name, name_ar, account_type, currency_code, is_control_account, opening_balance)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
           RETURNING id, code, name, name_ar, account_type, currency_code, is_control_account, opening_balance`,
          [req.auth.tenantId, parentId || null, code, name, nameAr || null, accountType, currencyCode, !!isControlAccount, openingBalance || 0]
        )
      );
      res.status(201).json({ account: result.rows[0] });
    } catch (err) {
      if (err.code === "23505") {
        return res.status(409).json({ error: "account_code_exists", message: `Account code "${code}" already exists.` });
      }
      console.error("create_account_error", err);
      res.status(500).json({ error: "failed_to_create_account" });
    }
  }
);

module.exports = router;
