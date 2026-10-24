
CREATE TABLE employer_details (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid REFERENCES profiles(id),
  employer text NOT NULL,
  role_title text NOT NULL,
  supervisor_name text,
  employer_phone text,
  employer_address jsonb,
  can_contact boolean DEFAULT false,
  is_current_employer boolean DEFAULT false,
  start_date date,
  end_date date,
  reason_for_leaving text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

COMMENT ON TABLE employer_details IS 'Employer contact metadata for job applications — supervisor names, phone numbers, addresses, and reasons for leaving';
;
