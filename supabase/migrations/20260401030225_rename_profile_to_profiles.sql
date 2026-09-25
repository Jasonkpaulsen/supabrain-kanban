
-- Rename table
ALTER TABLE public.profile RENAME TO profiles;

-- Rename primary key constraint
ALTER INDEX profile_pkey RENAME TO profiles_pkey;

-- Rename trigger
ALTER TRIGGER trg_profile_updated_at ON public.profiles RENAME TO trg_profiles_updated_at;

-- Add unique constraint on email
ALTER TABLE public.profiles ADD CONSTRAINT profiles_email_unique UNIQUE (email);
;
