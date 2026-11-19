-- =========================================================================
--             AL ZOAL - UPDATE DEFAULT BRANDING LOGO
-- =========================================================================
-- Version: 069 (sequentially assigned to avoid collision with 067_blog_authors_compatibility.sql)
-- Purpose: Replace legacy default ZOAL logo values without overwriting custom branding.

UPDATE public.branding_settings
SET
  business_logo = CASE
    WHEN business_logo IN (
      '/assets/branding/zoal-main-logo.jpg',
      '/images/branding/zoal-logo.jpg',
      '/images/branding/zoal-logo-4.jpg',
      '/images/branding/zoal-logo-4.png',
      '/images/zoal-logo-4.jpg',
      '/images/zoal_logo_transparent.png',
      '/images/branding/zoal%20logo,4-1.jpeg',
      '/assets/branding/favicon.jpg'
    ) THEN '/images/branding/zoal%20logo.4.jpeg'
    ELSE business_logo
  END,
  favicon = CASE
    WHEN favicon IN (
      '/assets/branding/zoal-main-logo.jpg',
      '/images/branding/zoal-logo.jpg',
      '/images/branding/zoal-logo-4.jpg',
      '/images/branding/zoal-logo-4.png',
      '/images/zoal-logo-4.jpg',
      '/images/zoal_logo_transparent.png',
      '/images/branding/zoal%20logo,4-1.jpeg',
      '/assets/branding/favicon.jpg'
    ) THEN '/images/branding/zoal%20logo.4.jpeg'
    ELSE favicon
  END,
  updated_at = NOW()
WHERE id = 1
  AND (
    business_logo IN (
      '/assets/branding/zoal-main-logo.jpg',
      '/images/branding/zoal-logo.jpg',
      '/images/branding/zoal-logo-4.jpg',
      '/images/branding/zoal-logo-4.png',
      '/images/zoal-logo-4.jpg',
      '/images/zoal_logo_transparent.png',
      '/images/branding/zoal%20logo,4-1.jpeg',
      '/assets/branding/favicon.jpg'
    )
    OR favicon IN (
      '/assets/branding/zoal-main-logo.jpg',
      '/images/branding/zoal-logo.jpg',
      '/images/branding/zoal-logo-4.jpg',
      '/images/branding/zoal-logo-4.png',
      '/images/zoal-logo-4.jpg',
      '/images/zoal_logo_transparent.png',
      '/images/branding/zoal%20logo,4-1.jpeg',
      '/assets/branding/favicon.jpg'
    )
  );
