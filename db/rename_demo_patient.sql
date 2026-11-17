-- Rename the demo patient CL-0032 to Rashid Khaleef in the live database.
-- Matches the change in data/build_dataset.py, so a later reload gives the same name.
update patients
   set given_name = 'Rashid',
       family_name = 'Khaleef',
       fhir = jsonb_set(fhir, '{entry}', (
         select jsonb_agg(case when e->'resource'->>'resourceType' = 'Patient'
                               then jsonb_set(e, '{resource,name}', '[{"family": "Khaleef", "given": ["Rashid"]}]')
                               else e end)
           from jsonb_array_elements(fhir->'entry') e))
 where mrn = 'CL-0032';

select mrn, given_name, family_name, birth_date, gp_id from patients where mrn = 'CL-0032';
