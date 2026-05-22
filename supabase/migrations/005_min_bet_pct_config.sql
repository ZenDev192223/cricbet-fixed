-- Add min_bet_pct config key (default 1%)
INSERT INTO system_config (key, value)
VALUES ('min_bet_pct', '1')
ON CONFLICT (key) DO NOTHING;
