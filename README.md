# Progetto-GitHub

A collection of reusable statistical programming templates for observational health data.
All dataset and variable names are generic: no data, study names or file paths are included.

## Disclaimer

This project was built on data from the Clinical Practice Research Datalink (CPRD), UK primary
care records. No CPRD data are included, and the project is not affiliated with or endorsed by
CPRD. Access to CPRD data requires a licence and approval of the study protocol.

The programs start from the CPRD data structure, and several steps are possible only because of it:

| Part of the program        | Why it depends on CPRD                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Numbered raw files         | CPRD extracts split clinical records and prescriptions across many files of the same type.                  |
| Code lists                 | Records are coded with medical and product codes, so each variable is defined by a list of codes.           |
| Patient and practice files | Year of birth, sex, registration dates and death date are in a patient file, region in a practice file.     |
| Eligibility                | The registration dates allow the check of baseline registration before the target event.                    |
| Measures                   | Heights, weights and BMI are recorded with a value and a unit code, in different and sometimes wrong units. |
| Smoking                    | General practitioners can record different smoking codes on the same day.                                   |
| Referrals                  | Referrals are in a separate file, linked to the clinical records that hold their date.                      |

With other data sources the structure of the input datasets has to be adapted first, and some steps
may not apply.

## SAS

### Raw data cleaning

[`SAS/raw_data_cleaning.sas`](SAS/raw_data_cleaning.sas) turns raw longitudinal health records
into a clean analysis dataset, with one row for each person. It is designed for data split across
many numbered files, as in electronic health record databases such as CPRD.

| Step          | What it does                                                                                                                                         |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Extraction    | Counts the raw files, then keeps the rows with a code in the code lists. The result is saved, so the slow extraction can be skipped on the next run. |
| Missing dates | Generic check and drop.                                                                                                                              |
| Target events | Keeps the target events in the study period.                                                                                                         |
| Eligibility   | Checks age, baseline registration, registration dates and death, and keeps the reason of each exclusion.                                             |
| Smoking       | Solves same day conflicts, then finds the most recent status before the target event.                                                                |
| Measures      | Converts heights to metres, drops values out of range and sets the labels to BMI, height or weight.                                                  |
| BMI           | Calculates BMI, prefers the recorded value, then finds the most recent one before the target event.                                                  |
| Cohort        | Keeps the first target event with both smoking status and BMI.                                                                                       |
| Exposure      | Finds the first exposure and drops people exposed before the target event.                                                                           |
| Referrals     | Counts the referrals before the target event.                                                                                                        |

### How to use it

1. Edit section 1 of the program: library paths and settings.
2. Make sure the input datasets below exist in those libraries.
3. Run the whole program with `run_extraction = 1`.
4. On later runs, set `run_extraction = 0` to reload the saved extraction.

The final datasets are saved in `LIB_OUT`.

### Input datasets

All input datasets are in `LIB_RAW`.

| Dataset                       | Content                          | Variables                                                           |
| ----------------------------- | -------------------------------- | ------------------------------------------------------------------- |
| `DATA_OBS1`, `DATA_OBS2`, ... | Clinical records                 | `id`, `obs_id`, `date`, `medical_code`, `value`, `unit`             |
| `DATA_RX1`, `DATA_RX2`, ...   | Prescriptions                    | `id`, `date`, `product_code`                                        |
| `DATA_PATIENT`                | One row for each person          | `id`, `practice`, `male`, `yob`, `regstart`, `regend`, `death_date` |
| `DATA_PRACTICE`               | One row for each practice        | `practice`, `region`                                                |
| `DATA_REFERRAL`               | Referrals                        | `id`, `obs_id`                                                      |
| `DATA_UNITS`                  | Measurement units                | `unit`, `description`                                               |
| `CODES_OBS`                   | Clinical code list               | `medical_code`, `definition`                                        |
| `CODES_RX`                    | Prescription code list           | `product_code`, `definition`                                        |
| `CODES_MEASURE`               | Height, weight and BMI code list | `medical_code`, `cat`                                               |

Always check variable format.

### Output datasets

| Dataset      | Content                                                                       |
| ------------ | ----------------------------------------------------------------------------- |
| `DATA_CLEAN` | Final dataset, one row for each person                                        |
| `DATA_SMOKE` | All cleaned smoking records                                                   |
| `DATA_BMI`   | One BMI for each person and day: `AgpBMI` if recorded, `calBMI` if calculated |

## Data protection

Patient-level data must never be committed. The [`.gitignore`](.gitignore) excludes SAS datasets,
logs and listings.

## License

Released under the [MIT License](LICENSE).
