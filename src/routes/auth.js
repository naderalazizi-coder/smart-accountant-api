const express = require("express");
const bcrypt = require("bcryptjs");
const { body, validationResult } = require("express-validator");
const { withoutTenant, pool } = require("../db/pool");
const { signToken, requireAuth } = require("../middleware/auth");

const router = express.Router();

/**
 * POST /auth/signup
 * Creates a brand-new, fully isolated company (tenant) plus its first
 * user (Owner role). No demo data is seeded — the new tenant starts
 * completely empty, exactly as requested. The user then adds their own
 * chart of accounts, customers, products, etc. from a clean slate.
 */
router.post(
  "/signup",
  [
    body("companyName").trim().notEmpty().withMessage("companyName is required"),
    body("fullName").trim().notEmpty().withMessage("fullName is required"),
    body("email").isEmail().withMessage("valid email is required"),
    body("password").isLength({ min: 8 }).withMessage("password must be at least 8 characters"),
  ],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ error: "validation_error", details: errors.array() });
    }

    const { companyName, companyNameAr, fullName, fullNameAr, email, password, baseCurrency } = req.body;
    const currency = baseCurrency || "USD";

    try {
      // Email must be globally unique — one person, one login, regardless
      // of how many companies exist in the system.
      const existing = await pool.query("SELECT 1 FROM users WHERE email = $1", [email.toLowerCase()]);
      if (existing.rowCount > 0) {
        return res.status(409).json({ error: "email_taken", message: "An account with this email already exists." });
      }

      const passwordHash = await bcrypt.hash(password, 12);

      const result = await withoutTenant(async (client) => {
        const tenantRes = await client.query(
          `INSERT INTO tenants (legal_name, legal_name_ar, base_currency_code)
           VALUES ($1, $2, $3) RETURNING id, legal_name, base_currency_code`,
          [companyName, companyNameAr || null, currency]
        );
        const tenant = tenantRes.rows[0];

        const branchRes = await client.query(
          `INSERT INTO branches (tenant_id, name, code, is_main)
           VALUES ($1, 'Main Branch', 'MAIN', true) RETURNING id`,
          [tenant.id]
        );
        const branch = branchRes.rows[0];

        const roleRes = await client.query(
          `INSERT INTO roles (tenant_id, name, is_system) VALUES ($1, 'Owner', true) RETURNING id`,
          [tenant.id]
        );
        const role = roleRes.rows[0];

        const userRes = await client.query(
          `INSERT INTO users (tenant_id, email, password_hash, full_name, full_name_ar, branch_id)
           VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, email, full_name, tenant_id`,
          [tenant.id, email.toLowerCase(), passwordHash, fullName, fullNameAr || null, branch.id]
        );
        const user = userRes.rows[0];

        await client.query(`INSERT INTO user_roles (user_id, role_id) VALUES ($1, $2)`, [user.id, role.id]);

        return { tenant, user };
      });

      const token = signToken({ id: result.user.id, tenant_id: result.tenant.id, email: result.user.email, role: "Owner" });

      res.status(201).json({
        token,
        tenant: { id: result.tenant.id, name: result.tenant.legal_name, currency: result.tenant.base_currency_code },
        user: { id: result.user.id, email: result.user.email, fullName: result.user.full_name, role: "Owner" },
      });
    } catch (err) {
      console.error("signup_error", err);
      res.status(500).json({ error: "signup_failed", message: "Could not create the account. Please try again." });
    }
  }
);

/**
 * POST /auth/login
 */
router.post(
  "/login",
  [body("email").isEmail(), body("password").notEmpty()],
  async (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(422).json({ error: "validation_error", details: errors.array() });
    }
    const { email, password } = req.body;

    try {
      const userRes = await pool.query(
        `SELECT u.id, u.email, u.password_hash, u.full_name, u.tenant_id, u.is_active,
                t.legal_name AS tenant_name, t.base_currency_code,
                COALESCE(r.name, 'Member') AS role
           FROM users u
           JOIN tenants t ON t.id = u.tenant_id
           LEFT JOIN user_roles ur ON ur.user_id = u.id
           LEFT JOIN roles r ON r.id = ur.role_id
          WHERE u.email = $1
          LIMIT 1`,
        [email.toLowerCase()]
      );

      if (userRes.rowCount === 0) {
        return res.status(401).json({ error: "invalid_credentials", message: "Incorrect email or password." });
      }
      const user = userRes.rows[0];
      if (!user.is_active) {
        return res.status(403).json({ error: "account_disabled", message: "This account has been disabled." });
      }

      const ok = await bcrypt.compare(password, user.password_hash);
      if (!ok) {
        return res.status(401).json({ error: "invalid_credentials", message: "Incorrect email or password." });
      }

      await pool.query("UPDATE users SET last_login_at = now() WHERE id = $1", [user.id]);

      const token = signToken({ id: user.id, tenant_id: user.tenant_id, email: user.email, role: user.role });

      res.json({
        token,
        tenant: { id: user.tenant_id, name: user.tenant_name, currency: user.base_currency_code },
        user: { id: user.id, email: user.email, fullName: user.full_name, role: user.role },
      });
    } catch (err) {
      console.error("login_error", err);
      res.status(500).json({ error: "login_failed", message: "Login failed. Please try again." });
    }
  }
);

/** GET /auth/me — confirms the token is valid and returns the current identity. */
router.get("/me", requireAuth, async (req, res) => {
  const userRes = await pool.query(
    `SELECT u.id, u.email, u.full_name, u.tenant_id, t.legal_name AS tenant_name, t.base_currency_code
       FROM users u JOIN tenants t ON t.id = u.tenant_id WHERE u.id = $1`,
    [req.auth.userId]
  );
  if (userRes.rowCount === 0) return res.status(404).json({ error: "not_found" });
  const u = userRes.rows[0];
  res.json({
    user: { id: u.id, email: u.email, fullName: u.full_name, role: req.auth.role },
    tenant: { id: u.tenant_id, name: u.tenant_name, currency: u.base_currency_code },
  });
});

module.exports = router;
