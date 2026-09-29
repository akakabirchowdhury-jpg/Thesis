# ============================================================
# 01_PREREQUISITES.R
# Everything 02_updated_exposures.R and 03_multigroup_sem.R need:
#   - ch_merged_agri: MICS 2012/2019/2025 merged, with district,
#     birth_date, birth_year, HAZ2/WAZ2/WHZ2, wscore, HL4
#   - district_day_full: daily kriged maxt_pred/mint_pred/rain_pred
#     for all 64 districts
#   - district_coords: 64 district centroids
# Does NOT build agricultural production data (02 does that itself
# from scratch with the 6-crop structure) or run any SEM (03 does).
# ============================================================
library(haven)
library(dplyr)
library(readr)
library(readxl)
library(sf)
library(gstat)
library(purrr)
library(lubridate)

setwd("D:/Monayer")

# ============================================================
# 1. MERGE MICS CHILD DATA (2012 / 2019 / 2025)
# ============================================================
ch2012 <- read_sav("ch2012.sav") %>%
  rename(UB1D = AG1D, UB1M = AG1M, UB1Y = AG1Y, UB2 = AG2)
ch2019 <- read_sav("ch2019.sav")
ch2025 <- read_sav("ch2025.sav")

common_cols <- Reduce(intersect, list(names(ch2012), names(ch2019), names(ch2025)))

ch_merged <- bind_rows(
  ch2012 %>% select(all_of(common_cols)) %>% mutate(survey_year = 2012),
  ch2019 %>% select(all_of(common_cols)) %>% mutate(survey_year = 2019),
  ch2025 %>% select(all_of(common_cols)) %>% mutate(survey_year = 2025)
)

# clean missing codes + build birth_date safely (make_date returns
# NA for invalid combos instead of erroring the whole vector)
ch_merged_agri <- ch_merged %>%
  mutate(
    UB1D_clean = if_else(UB1D %in% 1:31, UB1D, NA_real_),
    UB1M_clean = if_else(UB1M %in% 1:12, UB1M, NA_real_),
    UB1Y_clean = na_if(UB1Y, 9999),
    birth_year = as.numeric(UB1Y_clean),
    birth_date = make_date(UB1Y_clean, UB1M_clean, UB1D_clean)
  )

# ============================================================
# 2. STATION TEMPERATURE DATA -- cleaned (corrections baked in;
#    see station_data_cleaning_log.csv from earlier work for detail)
# ============================================================
station_xwalk <- read_csv("station_district_crosswalk.csv", show_col_types = FALSE)
# 43/44 stations have coordinates; St_ID 91850 excluded (unresolved).
# 6 stations use upazila-town coords (Tetulia/Dimla/Rajarhat/
# Badalgachhi/Tarash/Kumarkhali), sourced via web search, not exact
# station siting -- minor limitation, noted for methods section.

clean_temp_col <- function(x) {
  x_chr <- trimws(as.character(x))
  x_chr[x_chr %in% c("****", "***", "**", "*", "", "NA", "N/A")] <- NA
  as.numeric(x_chr)
}

max_temp_raw <- read_excel("Max_Temp.xlsx", sheet = 1) %>% mutate(excel_row = row_number() + 1)
min_temp_raw <- read_excel("Min_Temp.xlsx", sheet = 1) %>% mutate(excel_row = row_number() + 1)

# CORRECTION 1: St_ID 10208, rows 219923-219952 mislabeled Year=2023
# -> actually Apr 2024 (confirmed by chronological position in file)
fix_rows_10208 <- 219923:219952
max_temp_raw <- max_temp_raw %>% mutate(Year = if_else(excel_row %in% fix_rows_10208, 2024, Year))
min_temp_raw <- min_temp_raw %>% mutate(Year = if_else(excel_row %in% fix_rows_10208, 2024, Year))

# CORRECTION 2: rows 221810-221839 are a misplaced duplicate of
# St_ID 41851's June 2024 data sitting inside St_ID 10120's sequence.
# Drop -- a correct copy exists elsewhere; leaves 10120's Jun 2024
# genuinely missing.
drop_rows_41851_misplaced <- 221810:221839
max_temp_raw <- max_temp_raw %>% filter(!excel_row %in% drop_rows_41851_misplaced)
min_temp_raw <- min_temp_raw %>% filter(!excel_row %in% drop_rows_41851_misplaced)

max_temp <- max_temp_raw %>%
  mutate(MaxT = clean_temp_col(MaxT), date = as.Date(paste(Year, Month, Date, sep = "-"))) %>%
  filter(!is.na(date))   # CORRECTION 3: drops template rows (Date=31 in <31-day months)
min_temp <- min_temp_raw %>%
  mutate(MinT = clean_temp_col(MinT), date = as.Date(paste(Year, Month, Date, sep = "-"))) %>%
  filter(!is.na(date))

station_day <- max_temp %>%
  select(St_ID, date, Year, Month, MaxT) %>%
  full_join(min_temp %>% select(St_ID, date, MinT), by = c("St_ID", "date")) %>%
  left_join(station_xwalk %>% select(local_id, lat, lon), by = c("St_ID" = "local_id")) %>%
  filter(!is.na(lat), !is.na(lon))   # drops unresolved 91850

# ============================================================
# 3. RAINFALL DATA -- cleaned (same pattern, different missing code)
# ============================================================
clean_rain <- function(x) {
  x_chr <- trimws(as.character(x))
  x_chr[x_chr %in% c("**", "***", "****", "*", "", "NA", "N/A")] <- NA
  as.numeric(x_chr)
}

rain <- read_csv("Rainfall.csv", show_col_types = FALSE) %>%
  rename(St_ID = Station) %>%
  mutate(Rainfall = clean_rain(Rainfall), date = as.Date(paste(Year, Month, Day, sep = "-"))) %>%
  filter(!is.na(date)) %>%
  distinct(St_ID, date, .keep_all = TRUE) %>%
  left_join(station_xwalk %>% select(local_id, lat, lon), by = c("St_ID" = "local_id")) %>%
  filter(!is.na(lat), !is.na(lon))   # drops unresolved station IDs (incl. 91850, and 4 others with no source found)

# ============================================================
# 4. KRIGE TEMP + RAINFALL -> 64 DISTRICT CENTROIDS (DAILY)
# ============================================================
district_coords <- read_csv("districts_lat_lon.csv", show_col_types = FALSE)
district_sf <- st_as_sf(district_coords, coords = c("lon", "lat"), crs = 4326)

fit_monthly_variogram <- function(data, value_col, month_num) {
  month_data <- data %>%
    filter(Month == month_num, !is.na(.data[[value_col]])) %>%
    st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE)
  if (nrow(month_data) < 30) return(NULL)
  v_emp <- variogram(as.formula(paste(value_col, "~ 1")), month_data)
  tryCatch(fit.variogram(v_emp, vgm(psill = NA, model = "Sph", range = NA, nugget = NA)),
           error = function(e) NULL)
}

krige_one_day <- function(day_data, value_col, vgm_model, target_sf, floor_zero = FALSE) {
  day_sf <- day_data %>%
    filter(!is.na(.data[[value_col]])) %>%
    st_as_sf(coords = c("lon", "lat"), crs = 4326, remove = FALSE)
  if (nrow(day_sf) < 5 || is.null(vgm_model)) return(NULL)
  result <- tryCatch(krige(as.formula(paste(value_col, "~ 1")), day_sf, target_sf, model = vgm_model),
                      error = function(e) NULL)
  if (is.null(result)) return(NULL)
  pred <- if (floor_zero) pmax(result$var1.pred, 0) else result$var1.pred
  tibble(district = target_sf$district, pred = pred)
}

krige_series <- function(data, value_col, target_sf, floor_zero = FALSE) {
  variograms <- map(1:12, ~ fit_monthly_variogram(data, value_col, .x))
  all_dates <- sort(unique(data$date))
  out <- vector("list", length(all_dates))
  for (i in seq_along(all_dates)) {
    d <- all_dates[i]; m <- as.integer(format(d, "%m"))
    day_data <- data %>% filter(date == d)
    r <- krige_one_day(day_data, value_col, variograms[[m]], target_sf, floor_zero)
    if (!is.null(r)) out[[i]] <- r %>% mutate(date = d)
    if (i %% 1000 == 0) cat(value_col, "kriging...", i, "/", length(all_dates), "\n")
  }
  bind_rows(out)
}

maxt_district_day <- krige_series(station_day, "MaxT", district_sf) %>% rename(maxt_pred = pred)
mint_district_day <- krige_series(station_day, "MinT", district_sf) %>% rename(mint_pred = pred)
rain_district_day  <- krige_series(rain, "Rainfall", district_sf, floor_zero = TRUE) %>% rename(rain_pred = pred)

district_day_full <- maxt_district_day %>%
  full_join(mint_district_day, by = c("district", "date")) %>%
  full_join(rain_district_day, by = c("district", "date"))

saveRDS(district_day_full, "district_day_full.rds")

# ============================================================
# 5. HH7A (MICS district code) -> district name crosswalk
# ============================================================
hh7a_labels <- as_factor(ch_merged_agri$HH7A)
hh7a_levels <- levels(hh7a_labels)

norm_name <- function(x) tolower(gsub("[^a-z]", "", tolower(x)))
district_norm <- setNames(district_coords$district, norm_name(district_coords$district))

fuzzy_match <- function(label) {
  ln <- norm_name(label)
  if (ln %in% names(district_norm)) return(district_norm[[ln]])
  dists <- adist(ln, names(district_norm))
  best <- which.min(dists)
  if (dists[best] <= 2) return(district_norm[[best]])
  NA_character_
}
hh7a_xwalk <- tibble(hh7a_label = hh7a_levels) %>%
  mutate(district = map_chr(hh7a_label, fuzzy_match))

# manual overrides for labels the fuzzy matcher can't resolve
manual_overrides <- tibble::tribble(
  ~hh7a_label,                     ~district,
  "Brahmanbaria",                  "Bbaria",
  "CHATTOGRAM CITY CORPORATION",   "Chittagong",
  "DHAKA SOUTH CITY CORPORATION",  "Dhaka",
  "DHAKA NORTH CITY CORPORATION",  "Dhaka",
  "Kishorganj",                    "Kishoregong",
  "Nawabganj",                     "Chapai"
)
hh7a_xwalk <- hh7a_xwalk %>% rows_update(manual_overrides, by = "hh7a_label")

stopifnot(sum(is.na(hh7a_xwalk$district)) == 0)  # should be zero after overrides

ch_merged_agri <- ch_merged_agri %>%
  mutate(hh7a_label = as.character(as_factor(HH7A))) %>%
  left_join(hh7a_xwalk %>% mutate(hh7a_label = as.character(hh7a_label)), by = "hh7a_label")

stopifnot(sum(!is.na(ch_merged_agri$district)) == nrow(ch_merged_agri))  # all rows matched

cat("\nPrerequisites built: ch_merged_agri (", nrow(ch_merged_agri), "rows),",
    "district_day_full (", nrow(district_day_full), "rows), district_coords ready.\n")
cat("Proceed to 02_updated_exposures.R\n")
