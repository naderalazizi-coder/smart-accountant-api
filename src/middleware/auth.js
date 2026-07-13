const jwt = require("jsonwebtoken");

const JWT_SECRET = process.env.JWT_SECRET || "dev-secret-change-me";

function requireAuth(req, res, next) {
  const header = req.headers.authorization || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) {
    return res.status(401).json({ error: "missing_token", message: "Authorization header is required." });
  }
  try {
    const payload = jwt.verify(token, JWT_SECRET);
    req.auth = { userId: payload.sub, tenantId: payload.tenantId, email: payload.email, role: payload.role };
    next();
  } catch (err) {
    return res.status(401).json({ error: "invalid_token", message: "Session expired or invalid. Please log in again." });
  }
}

function signToken(user) {
  return jwt.sign(
    { sub: user.id, tenantId: user.tenant_id, email: user.email, role: user.role },
    JWT_SECRET,
    { expiresIn: "12h" }
  );
}

module.exports = { requireAuth, signToken, JWT_SECRET };
