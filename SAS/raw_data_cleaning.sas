/*==============================================================================
  RAW DATA CLEANING

  Builds a clean analysis dataset from raw longitudinal health records: one row
  for each person, with the first eligible target event, smoking status, BMI,
  first exposure and number of recent referrals.
  Input and output datasets are described in the README.

  Disclaimer:
    This program was built on data from the Clinical Practice Research Datalink
    (CPRD). No CPRD data are included. Several steps depend on the CPRD data
    structure: numbered raw files, coded records with code lists, patient and
    practice files, registration dates, measures with unit codes and referrals
    linked to clinical records. With other data sources the input datasets have
    to be adapted first, and some steps may not apply. See the README.

  Sections:
     1. Settings
     2. Macros
     3. Raw data extraction
     4. Eligible target events
     5. Smoking status
     6. Height, weight and BMI records cleaning
     7. BMI calculation
     8. Smoking and BMI on the cohort
     9. Exposure
    10. Referrals
    11. Save final datasets
==============================================================================*/




/*------------------------------------------------------------------------------
  1. SETTINGS - this is the only section to edit
------------------------------------------------------------------------------*/

/* library dataset */
libname LIB_RAW "C:\path\to\raw data" access=readonly;    /* raw files, code lists */
libname LIB_OUT "C:\path\to\output";                      /* saved datasets */


/* RUN MODE
   1 = read the raw files (slow), then save the extraction in LIB_OUT
   0 = skip the raw files and reload the extraction already saved in LIB_OUT */
%let run_extraction = 1;


/* DEFINITION LABELS
   Values of DEFINITION in the code lists that identify the two main groups of records */
%let target_event = TARGET;      /* the event that defines entry in the cohort */
%let exposure     = EXPOSURE;    /* the prescription under study */


/* TARGET EVENT PERIOD
   Target events are kept only from 1 January of FIRST_YEAR to 31 December of LAST_YEAR */
%let first_year = 1995;
%let last_year  = 2017;


/* ELIGIBILITY
   MIN_AGE:        minimum age, in years, at the target event
   BASELINE_YEARS: minimum years of registration before the target event */
%let min_age        = 30;
%let baseline_years = 1;


/* COVARIATE PERIOD
   Smoking and BMI records outside these dates are not used */
%let covar_start = 01JAN1990;
%let covar_end   = 30SEP2021;


/* LOOK-BACK WINDOWS, counted back from the target event or the weight record
   LOOKBACK_YEARS: search for the most recent smoking status and BMI
   HEIGHT_YEARS:   average of the heights, used when a weight has no height on the same day
   REFERRAL_MONTHS: count of the referrals */
%let lookback_years  = 4;
%let height_years    = 5;
%let referral_months = 3;


/* ACCEPTED VALUES: records outside these ranges are dropped */
%let min_bmi    = 10;     /* kg/m2 */
%let max_bmi    = 60;     /* kg/m2 */
%let min_height = 1;      /* metres */
%let max_height = 2.5;    /* metres */
%let min_weight = 10;     /* kg */
%let max_weight = 300;    /* kg */


/* BMI CUT-OFFS, used to read the values recorded with a descriptive code
   UNDER_BMI: below this value the person is underweight
   OVER_BMI:  from this value the person is overweight
   OBESE_BMI: from this value the person is obese */
%let under_bmi = 18.5;
%let over_bmi  = 25;
%let obese_bmi = 30;


/* SAME DAY BMI
   Maximum difference between BMI values of one person on the same day.
   If the difference is larger the day is dropped, because the values are not reliable */
%let max_bmi_diff = 1;


/* UNITS
   Measurement units that can not be converted, records with these units are dropped */
%let bad_units = '%', 'decimal stones', 'UI', 'stone', '8CAL';




/*------------------------------------------------------------------------------
  2. MACROS
------------------------------------------------------------------------------*/

/* COUNT_FILES
   Counts the numbered files of a library, for example DATA_OBS1, DATA_OBS2, ...
   The calling macro has to declare the variable named in OUT as %local.

   lib    = library to search
   prefix = name of the files without the number
   out    = name of the macro variable that receives the result */
%macro count_files(lib=, prefix=, out=);

  proc sql noprint;
    select count(*)
    into   :&out trimmed
    from   dictionary.tables
    where  libname = "%upcase(&lib)"
           and memtype = 'DATA'
           and prxmatch("/^%upcase(&prefix)\d+$/", strip(memname)) > 0;
  quit;

%mend;


/* EXTRACT_FILES
   Reads every numbered file and keeps only the rows with a code in the code list.
   Rows from all the files are appended into one dataset.

   lib    = library of the raw files
   prefix = name of the raw files without the number
   codes  = code list
   key    = code variable, with the same name in the raw files and in the code list
   label  = variable of the code list to add to the output
   out    = name of the output dataset */
%macro extract_files(lib=, prefix=, codes=, key=, label=, out=);
  %local n i;

  /* number of files to read: the value is printed in the log */
  %count_files(lib=&lib, prefix=&prefix, out=n);
  %put &prefix: &n files found;

  %if &n = 0 %then %do;
    %put ERROR: no &prefix files found in library &lib;
    %return;
  %end;

  /* one subset for each file */
  proc sql;
  %do i = 1 %to &n;
    create table work.Subset&i. as
    select a.*,
           b.&label
    from   &lib..&prefix&i as a,
           &codes          as b
    where  a.&key = b.&key;
  %end;
  quit;

  /* append all created subsets into one dataset */
  data &out;
    set Subset1 - Subset&n;
  run;

  /* drop temporary datasets */
  proc datasets lib=work nolist;
    delete Subset1 - Subset&n;
  quit;

%mend;


/* EXTRACT_REFERRALS
   Referrals have no date: the date is in the observation file linked by ID and OBS_ID.
   This macro reads each observation file and adds the date to the referrals.

   lib = library of the raw files
   out = name of the output dataset */
%macro extract_referrals(lib=, out=);
  %local n i;

  %count_files(lib=&lib, prefix=DATA_OBS, out=n);

  /* one subset for each observation file */
  proc sql;
  %do i = 1 %to &n;
    create table work.Subset&i. as
    select a.id,
           a.obs_id,
           a.date
    from   &lib..DATA_OBS&i    as a,
           &lib..DATA_REFERRAL as b
    where  a.id = b.id
           and a.obs_id = b.obs_id
           and not missing(a.date);
  %end;
  quit;

  /* append all created subsets into one dataset */
  data &out;
    set Subset1 - Subset&n;
  run;

  /* drop temporary datasets */
  proc datasets lib=work nolist;
    delete Subset1 - Subset&n;
  quit;

%mend;


/* LOAD_RECORDS
   Runs the extraction and saves the result, or reloads a previous extraction.
   The choice depends on RUN_EXTRACTION, in the settings. */
%macro load_records;

  %if &run_extraction = 1 %then %do;

    /* clinical records and prescriptions of interest */
    %extract_files(lib=LIB_RAW, prefix=DATA_OBS, codes=LIB_RAW.CODES_OBS,
                   key=medical_code, label=definition, out=RECORDS_OBS);
    %extract_files(lib=LIB_RAW, prefix=DATA_RX,  codes=LIB_RAW.CODES_RX,
                   key=product_code, label=definition, out=RECORDS_RX);

    /* one dataset with both */
    data DATA_ALL;
      set RECORDS_RX
          RECORDS_OBS;
    run;

    /* heights, weights and BMI recorded with any code */
    %extract_files(lib=LIB_RAW, prefix=DATA_OBS, codes=LIB_RAW.CODES_MEASURE,
                   key=medical_code, label=cat, out=DATA_MEASURE);

    %extract_referrals(lib=LIB_RAW, out=DATA_REF);

    /* the extraction is slow, so save it to skip this step on the next run */
    data LIB_OUT.DATA_ALL;     set DATA_ALL;     run;
    data LIB_OUT.DATA_MEASURE; set DATA_MEASURE; run;
    data LIB_OUT.DATA_REF;     set DATA_REF;     run;

  %end;
  %else %do;

    data DATA_ALL;     set LIB_OUT.DATA_ALL;     run;
    data DATA_MEASURE; set LIB_OUT.DATA_MEASURE; run;
    data DATA_REF;     set LIB_OUT.DATA_REF;     run;

  %end;

%mend;


/* DAILY_MEAN
   Reduces BMI records to one value for each person and day: the mean of the different
   values. Days with values too far apart (see MAX_BMI_DIFF) are dropped.

   in    = input dataset, with variables ID, DATE and VALUE
   label = value of DEFINITION in the output, to know the origin of the BMI
   out   = name of the output dataset */
%macro daily_mean(in=, label=, out=);

  proc sql;
    create table &out as
    select   id,
             date,
             mean(distinct raw_value) as value,
             "&label"                 as definition length=10
    from     &in (rename=(value=raw_value))
    group by id, date
    having   max(raw_value) - min(raw_value) <= &max_bmi_diff
    order by id, date;
  quit;

%mend;


/* LAST_VALUE
   For each eligible target event, finds the most recent record of the input dataset
   in the LOOKBACK_YEARS before the event. Events without such a record are dropped.

   in       = input dataset, with variables ID and DATE
   var      = variable of the input dataset with the value to read
   new      = name of that value in the output
   new_date = name of the date of that value in the output
   out      = name of the output dataset */
%macro last_value(in=, var=, new=, new_date=, out=);

  proc sql;

    /* date of the most recent record */
    create table LAST_DATE as
    select   a.id,
             a.date      as event_date,
             max(b.date) as &new_date format=date9.
    from     DATA5 as a,
             &in   as b
    where    a.id = b.id
             and intnx('year', a.date, -&lookback_years, 'same') <= b.date <= a.date
    group by a.id, a.date;

    /* value recorded on that date */
    create table &out as
    select   a.*,
             b.&var as &new
    from     LAST_DATE as a,
             &in       as b
    where    a.id = b.id
             and a.&new_date = b.date
    order by id, event_date;

  quit;

%mend;




/*------------------------------------------------------------------------------
  3. RAW DATA EXTRACTION
------------------------------------------------------------------------------*/

%load_records;


/* if event with missing date then exclude */
data DATA_ALL;
  set DATA_ALL;
  where not missing(date);
run;




/*------------------------------------------------------------------------------
  4. ELIGIBLE TARGET EVENTS
     Each step reads the previous one (DATA1, DATA2, ...), so the number of rows
     dropped by each criterion can be read in the log.
------------------------------------------------------------------------------*/

/* target events in the study period */
data DATA1;
  set DATA_ALL;
  where definition = "&target_event"
        and "01JAN&first_year"d <= date <= "31DEC&last_year"d;
  keep id date definition;
run;


/* first year in the study period when each person has at least MIN_AGE years.
   AGE_YEAR is missing if the person never reaches that age in the period */
data PATIENT;
  set LIB_RAW.DATA_PATIENT;
  age_year = max(&first_year, yob + &min_age);
  if age_year > &last_year then age_year = .;
run;


/* add patient and practice information to the target events */
proc sql;
  create table DATA2 as
  select a.id,
         a.date,
         a.definition,
         b.male,
         b.yob,
         b.regstart,
         b.regend,
         b.death_date,
         b.age_year,
         c.region
  from   DATA1                as a,
         PATIENT              as b,
         LIB_RAW.DATA_PRACTICE as c
  where  a.id = b.id
         and b.practice = c.practice;
quit;


/* drop if event date before birth year */
data DATA3;
  set DATA2;
  where year(date) >= yob;
run;


/* eligibility of each target event, the reason of exclusion is kept in EL:
    1 = eligible
   30 = never reaches MIN_AGE in the study period
   96 = event before the start of registration
   97 = event on or after the end of registration
   98 = less than BASELINE_YEARS of registration before the event
   99 = event before MIN_AGE
   The checks are in order: the last one that is true sets the value of EL */
data DATA4;
  set DATA3;

  if missing(age_year) then el = 30;
  else do;
    age_date      = mdy(1, 1, age_year);                               /* 1 January of AGE_YEAR */
    baseline_date = intnx('year', date, -&baseline_years, 'same');     /* latest accepted start of registration */

    if age_date <= date and regstart <= baseline_date then el = 1;
    if age_date >  date and regstart <= baseline_date then el = 99;
    if regstart > baseline_date                       then el = 98;
    if not missing(regend)   and date >= regend       then el = 97;
    if not missing(regstart) and date <  regstart     then el = 96;
  end;

  drop age_date baseline_date;
run;

proc freq data=DATA4;
  table el;
run;


/* status at the end of registration:
    1 = registration ended with death
    0 = registration ended without death (censored)
   99 = registration still in progress */
data DATA4;
  set DATA4;
  if not missing(regend) then do;
    if not missing(death_date) then dead = 1;
    else                            dead = 0;
  end;
  else                              dead = 99;
run;


/* keep eligible events, excluding those on or after the date of death */
data DATA5;
  set DATA4;
  where el = 1
        and (date < death_date or missing(death_date));
run;


/* delete duplicate rows */
proc sort data=DATA5 nodupkey;
  by id date;
run;


/* list of eligible people: smoking and BMI are prepared only for them */
proc sort data=DATA5 (keep=id) out=COHORT_ID nodupkey;
  by id;
run;




/*------------------------------------------------------------------------------
  5. SMOKING STATUS
------------------------------------------------------------------------------*/

/* smoking records of eligible people, in the covariate period */
data SMOKE1;
  set DATA_ALL;
  where definition in ('smoking', 'nonsmoker', 'smoking cessation', 'exsmoker')
        and "&covar_start"d <= date <= "&covar_end"d;
  keep id date definition;
run;

proc sort data=SMOKE1;
  by id date;
run;

data SMOKE2;
  merge SMOKE1    (in=a)
        COHORT_ID (in=b);
  by id;
  if a and b;
run;


/* days with more than one different smoking status for the same person */
proc sql;
  create table SMOKE_CONFLICT as
  select unique a.id,
         a.date
  from   SMOKE2 as a,
         SMOKE2 as b
  where  a.id = b.id
         and a.date = b.date
         and a.definition ~= b.definition
  order  by a.id, a.date;
quit;


/* set these days to smoking, because each combination of different status brings to smoking
   condition. Smoking cessation is also smoking: the person was still a smoker on that date */
data SMOKE3;
  merge SMOKE2         (in=a)
        SMOKE_CONFLICT (in=b);
  by id date;
  if a;
  if b or definition = 'smoking cessation' then definition = 'smoking';
run;


/* one row for each person, day and status */
proc sort data=SMOKE3 out=DATA_SMOKE nodupkey;
  by id date definition;
run;


/* most recent smoking status before each target event */
%last_value(in=DATA_SMOKE, var=definition, new=smoke_status, new_date=smoke_date, out=LAST_SMOKE);




/*------------------------------------------------------------------------------
  6. HEIGHT, WEIGHT AND BMI RECORDS CLEANING
------------------------------------------------------------------------------*/

/* BMI recorded as such, of eligible people, in the covariate period and in the accepted range */
data BMI1;
  set DATA_ALL;
  where definition = 'BMI'
        and "&covar_start"d <= date <= "&covar_end"d
        and &min_bmi <= value <= &max_bmi;
  keep id date value;
run;

proc sort data=BMI1;
  by id date;
run;

data BMI2;
  merge BMI1      (in=a)
        COHORT_ID (in=b);
  by id;
  if a and b;
run;


/* height, weight and BMI records of eligible people: without a date or a value they can not be used */
data MEASURE1;
  set DATA_MEASURE;
  where not missing(date)
        and not missing(value)
        and "&covar_start"d <= date <= "&covar_end"d;
  keep id date cat medical_code value unit;
run;

proc sort data=MEASURE1;
  by id;
run;

data MEASURE2;
  merge MEASURE1  (in=a)
        COHORT_ID (in=b);
  by id;
  if a and b;
run;


/* add the description of the units, then drop those that can not be converted */
proc sql;
  create table MEASURE3 as
  select    a.*,
            b.description
  from      MEASURE2 as a
  left join LIB_RAW.DATA_UNITS as b
  on        a.unit = b.unit
  where     b.description not in (&bad_units)
  order by  id, cat, date;
quit;


/* height recorded in cm or mm: convert to metres */
data MEASURE4;
  set MEASURE3;
  if cat = 'Height' and 100 <= value < 1000 then do;
    value       = value / 100;
    description = 'cm/100';
  end;
  if cat = 'Height' and value >= 1000 then do;
    value       = value / 1000;
    description = 'cm/1000';
  end;
run;


/* drop values out of range. The first three checks use the unit, the others the code label */
data MEASURE5;
  set MEASURE4;

  if description in ('kg/m2')       and not (&min_bmi    <= value <= &max_bmi)    then delete;
  if description in ('m', 'cm/100') and not (&min_height <= value <= &max_height) then delete;
  if description in ('kg')          and not (&min_weight <= value <= &max_weight) then delete;

  if cat in ('BMI', 'BMInormal')     and not (&min_bmi    <= value <= &max_bmi)    then delete;
  if cat in ('Height')               and not (&min_height <= value <= &max_height) then delete;
  if cat in ('Weight')               and not (&min_weight <= value <= &max_weight) then delete;
  if cat in ('Obesity', 'HOobesity') and not (&min_bmi    <= value <= &max_weight) then delete;
  if cat in ('Overweight')           and not (&over_bmi   <= value <= &max_weight) then delete;
  if cat in ('Underweight')          and not (&min_bmi    <= value <= &max_weight) then delete;
run;


/* set just three possible labels: BMI, Height, Weight.
   A descriptive code (for example Obesity) can hold a BMI or a weight:
   the unit decides when it is kg, otherwise the size of the value */
data MEASURE6;
  set MEASURE5;

  if cat in ('BMInormal') then cat = 'BMI';

  if cat in ('Obesity', 'HOobesity', 'Overweight', 'Underweight') then do;
    if description = 'kg' then cat = 'Weight';

    else if cat in ('Obesity', 'HOobesity') then do;
      if value <= &max_bmi then cat = 'BMI';
      else                      cat = 'Weight';
    end;

    else if cat = 'Overweight' and value < &obese_bmi then cat = 'BMI';
    else if cat = 'Underweight' and value < &under_bmi then cat = 'BMI';
  end;
run;




/*------------------------------------------------------------------------------
  7. BMI CALCULATION
------------------------------------------------------------------------------*/

/* heights and weights, one row for each different value */
proc sort data=MEASURE6 (where=(cat = 'Height') rename=(value=height) keep=id date cat value)
          out=HEIGHT nodupkey;
  by id date height;
run;

proc sort data=MEASURE6 (where=(cat = 'Weight') rename=(value=weight) keep=id date cat value)
          out=WEIGHT nodupkey;
  by id date weight;
run;


/* round height */
data HEIGHT;
  set HEIGHT;
  height = round(height, 0.01);
  drop cat;
run;


/* each weight with the height of the same day: height is missing if there is none */
proc sql;
  create table BMI_CALC1 as
  select    a.id,
            a.date,
            a.weight,
            b.height
  from      WEIGHT as a
  left join HEIGHT as b
  on        a.id = b.id
            and a.date = b.date
  order by  a.id, a.date;
quit;


/* at each weight, calculate average height in the prior HEIGHT_YEARS.
   Weights with no height in this period are dropped */
proc sql;
  create table BMI_CALC2 as
  select   a.*,
           round(mean(b.height), 0.01) as mean_height
  from     BMI_CALC1 as a,
           HEIGHT    as b
  where    a.id = b.id
           and intnx('year', a.date, -&height_years, 'same') <= b.date <= a.date
  group by a.id, a.date, a.height, a.weight
  order by a.id, a.date;
quit;


/* calculate BMI: with the height of the same day, otherwise with the average height */
data BMI_CALC3;
  set BMI_CALC2;
  if not missing(height) then value = weight / (height**2);
  else                        value = weight / (mean_height**2);
  keep id date value;
run;


/* if value not in BMI range */
data BMI_CALC4;
  set BMI_CALC3;
  where &min_bmi <= value <= &max_bmi;
run;


/* one calculated BMI for each person and day */
%daily_mean(in=BMI_CALC4, label=calBMI, out=BMI_CALC);


/* add the records with a BMI value from the cleaning step on the BMI recorded as such */
data BMI_REC1;
  set BMI2
      MEASURE6 (where=(cat = 'BMI' and &min_bmi <= value <= &max_bmi) keep=id date cat value);
  keep id date value;
run;


/* one recorded BMI for each person and day */
%daily_mean(in=BMI_REC1, label=AgpBMI, out=BMI_REC);


/* one BMI for each person and day: recorded if present, calculated otherwise.
   The labels are in alphabetical order, so AgpBMI comes first in each day */
data BMI_ALL;
  set BMI_CALC
      BMI_REC;
run;

proc sort data=BMI_ALL;
  by id date definition;
run;

data DATA_BMI;
  set BMI_ALL;
  by id date;
  if first.date;
run;


/* most recent BMI before each target event */
%last_value(in=DATA_BMI, var=value, new=bmi, new_date=bmi_date, out=LAST_BMI);




/*------------------------------------------------------------------------------
  8. SMOKING AND BMI ON THE COHORT
------------------------------------------------------------------------------*/

/* target events that have both a smoking status and a BMI */
proc sql;
  create table DATA6 as
  select   a.id,
           a.date as event_date format=date9.,
           a.definition as event,
           a.el,
           a.male,
           a.yob,
           a.regstart,
           a.regend,
           a.death_date,
           a.age_year,
           a.region,
           a.dead,
           b.smoke_date,
           b.smoke_status,
           c.bmi_date,
           c.bmi
  from     DATA5      as a,
           LAST_SMOKE as b,
           LAST_BMI   as c
  where    a.id = b.id
           and a.id = c.id
           and a.date = b.event_date
           and a.date = c.event_date
  order by a.id, a.date;
quit;


/* one row for each person: the first target event */
data DATA7;
  set DATA6;
  by id;
  if first.id;
run;




/*------------------------------------------------------------------------------
  9. EXPOSURE
------------------------------------------------------------------------------*/

/* first exposure of each person in the cohort */
proc sql;
  create table EXPOSURE1 as
  select   id,
           min(date) as exp_date format=date9.
  from     DATA_ALL
  where    definition = "&exposure"
           and id in (select id from DATA7)
  group by id;

  /* add the information on main dataset */
  create table DATA8 as
  select    a.*,
            b.exp_date
  from      DATA7 as a
  left join EXPOSURE1 as b
  on        a.id = b.id
  order by  a.id;
quit;


/* drop if first exposure is before the target event: these are prevalent users.
   People exposed later or never exposed are kept, and a registration that ends before the
   exposure is not an exclusion: to avoid selection bias they contribute as controls until then */
data DATA9;
  set DATA8;
  where missing(exp_date) or event_date <= exp_date;
run;




/*------------------------------------------------------------------------------
  10. REFERRALS
------------------------------------------------------------------------------*/

/* number of referrals in the REFERRAL_MONTHS before the target event */
proc sql;
  create table REFERRAL as
  select   a.id,
           count(b.id) as num_referral
  from     DATA9    as a,
           DATA_REF as b
  where    a.id = b.id
           and intnx('month', a.event_date, -&referral_months, 'same') <= b.date <= a.event_date
  group by a.id
  order by a.id;
quit;


/* add the information on main dataset: without referrals the number is 0 */
data DATA_CLEAN;
  merge DATA9    (in=a)
        REFERRAL (in=b);
  by id;
  if a;
  if missing(num_referral) then num_referral = 0;
run;

proc means data=DATA_CLEAN;
  var num_referral;
run;

proc freq data=DATA_CLEAN;
  table num_referral;
run;




/*------------------------------------------------------------------------------
  11. SAVE FINAL DATASETS
------------------------------------------------------------------------------*/

data LIB_OUT.DATA_CLEAN; set DATA_CLEAN; run;
data LIB_OUT.DATA_SMOKE; set DATA_SMOKE; run;
data LIB_OUT.DATA_BMI;   set DATA_BMI;   run;
