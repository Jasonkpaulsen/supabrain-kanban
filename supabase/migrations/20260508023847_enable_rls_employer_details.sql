
-- Enable RLS on employer_details
ALTER TABLE public.employer_details ENABLE ROW LEVEL SECURITY;

-- Authenticated users can SELECT their own rows
CREATE POLICY "auth_select_employer_details"
  ON public.employer_details
  FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- Authenticated users can INSERT their own rows
CREATE POLICY "auth_insert_employer_details"
  ON public.employer_details
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Authenticated users can UPDATE their own rows
CREATE POLICY "auth_update_employer_details"
  ON public.employer_details
  FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Authenticated users can DELETE their own rows
CREATE POLICY "auth_delete_employer_details"
  ON public.employer_details
  FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);
;
