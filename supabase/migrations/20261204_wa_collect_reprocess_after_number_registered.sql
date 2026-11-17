-- Applied live. A report sent from a number that was not yet registered used to be ignored for good (e.g. Rabia Rehman, 16 Nov 07:08, EMIS 32220167,
-- registered at 07:25). Now, when a cell number is added or re-activated for a school contact, a group member, or an AEO/admin profile, that number's
-- ignored messages of the last 48 hours are read again (fn_wa_collect_reprocess_unregistered) and saved as pending entries if the EMIS code and format are right.
-- Triggers: wa_collect_contacts_reprocess, wa_collect_members_reprocess, wa_collect_profile_reprocess. The live functions are authoritative.
select 1;
