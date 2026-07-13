-- Global reference data only. No demo/company data — every tenant that
-- signs up starts completely empty, as requested.
INSERT INTO currencies (code, name, name_ar, symbol, decimals) VALUES
  ('USD', 'US Dollar', 'دولار أمريكي', '$', 2),
  ('YER', 'Yemeni Rial', 'ريال يمني', '﷼', 2),
  ('SAR', 'Saudi Riyal', 'ريال سعودي', '﷼', 2),
  ('EUR', 'Euro', 'يورو', '€', 2)
ON CONFLICT DO NOTHING;
