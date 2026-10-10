ALTER TABLE public.projects DROP CONSTRAINT projects_domain_check;
ALTER TABLE public.projects ADD CONSTRAINT projects_domain_check
  CHECK (domain = ANY (ARRAY['products','business','career','property','operations','family','hobbies','club','gambling']));;
