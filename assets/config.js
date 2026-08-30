// SMP frontend config - safe to be public: this is the anon key, meant to be
// exposed client-side (protected by RLS + the login edge function), not a secret.
const SMP_CONFIG = {
  SUPABASE_URL: "https://gsswgpqrphqfomvsdooz.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdzc3dncHFycGhxZm9tdnNkb296Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5NjE3OTUsImV4cCI6MjEwMjUzNzc5NX0.8NPY8wXzb99eopHpn-lMjSGPfayGAccz-g9f-Ob6gjQ",
};
