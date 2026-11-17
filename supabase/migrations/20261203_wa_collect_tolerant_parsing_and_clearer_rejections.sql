-- Applied live (patch of fn_wa_collect_ingest, the WhatsApp consumption-reply reader). Summary of what changed, from the 25 rejected messages logged in wa_collect_issues:
--  1. "Date" line without the colon ("Date  Monday 16 Nov 2026", "Date Thursday. 12 Nov 2026") is now read (was: date_missing, 5 messages).
--  2. "Product: Biscuit" (singular) and a missing colon after Product are accepted (was: product_missing).
--  3. A date that is not a day of that product now says so with the nearest distribution days, e.g.
--     "Biscuits is not distributed on Wednesday 04 Nov (Biscuits days near it: Thursday 05 Nov) - please check the date" (was: not_consumption_day, 2).
--  4. wrong_markaz / outside_group_jurisdiction replies now name the school's markaz and what to do (11 messages on 28 Oct, before the AEO's markaz was assigned).
--  5. An EMIS code with 5-7 digits is answered "must have 8 digits - you sent X" and suggests the school in the sender's own area where one digit is missing
--     (e.g. 3222545 -> 32220545) (was: format_unreadable, 3). Nothing is guessed or saved automatically.
-- The patch was applied with a DO block doing replace() on pg_get_functiondef('fn_wa_collect_ingest'); the live function is authoritative.
select 1;
