
UPDATE public.job_applications 
SET decision = 'skip', 
    status = 'skipped', 
    updated_at = now() 
WHERE id = '290b0a18-e26a-428b-8076-0f0388d26784';
;
