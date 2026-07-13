require("dotenv").config();
const express = require("express");
const cors = require("cors");

const authRoutes = require("./routes/auth");
const accountsRoutes = require("./routes/accounts");
const journalRoutes = require("./routes/journal");
const periodsRoutes = require("./routes/periods");
const { migrate } = require("./db/migrate");

const app = express();
app.use(cors());
app.use(express.json());

app.get("/health", (req, res) => res.json({ status: "ok", service: "smart-accountant-api" }));

app.use("/auth", authRoutes);
app.use("/api/accounts", accountsRoutes);
app.use("/api/journal-entries", journalRoutes);
app.use("/api/periods", periodsRoutes);

app.use((req, res) => res.status(404).json({ error: "not_found", path: req.path }));

app.use((err, req, res, next) => {
  console.error("unhandled_error", err);
  res.status(500).json({ error: "internal_error" });
});

const PORT = process.env.PORT || 3000;
migrate()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`Smart Accountant API listening on port ${PORT}`);
    });
  })
  .catch((err) => {
    console.error("Migration failed — server not started.", err);
    process.exit(1);
  });
