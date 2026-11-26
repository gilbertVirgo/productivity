// API for the friends page. Anon keys are public by design (RLS + share_data guard the data).
// Served from 127.0.0.1/localhost → the local stack; anywhere else (GitHub Pages) → the hosted project.
window.STINT = /^(127\.0\.0\.1|localhost)$/.test(location.hostname)
  ? { api: "http://127.0.0.1:54321",
      key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0" }
  : { api: "https://vaidmipsctbcgxeescqj.supabase.co",
      key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZhaWRtaXBzY3RiY2d4ZWVzY3FqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTU2OTI4MzQsImV4cCI6MjExMTI2ODgzNH0.oI86qnzPMGc4UXD8bZx1i5gDA1rqyqR3NaUR6hncJ98" };
