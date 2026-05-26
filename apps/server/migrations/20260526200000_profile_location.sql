-- Profile location text (city, region, country — free-form). Pairs with the
-- existing timezone column so the profile sheet can render "Berlin · UTC+1
-- · 09:47 local" on a single line. 80-char cap to leave headroom for
-- "Tokyo, Japan" but reject prose.
ALTER TABLE users ADD COLUMN IF NOT EXISTS location TEXT;
