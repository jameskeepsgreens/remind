# |  (C) 2006-2020 Potsdam Institute for Climate Impact Research (PIK)
# |  authors, and contributors see CITATION.cff file. This file is part
# |  of REMIND and licensed under AGPL-3.0-or-later. Under Section 7 of
# |  AGPL-3.0, you are granted additional permissions described in the
# |  REMIND License Exception, version 1.0 (see LICENSE file).
# |  Contact: remind@pik-potsdam.de
########################################################################################################
#################################  U S E R   S E T T I N G S ###########################################
########################################################################################################

# Please provide all files and paths relative to the folder where start_coupled is executed
path_remind <- paste0(getwd(),"/")   # provide path to REMIND. Default: the actual path which the script is started from
path_magpie <- "/p/projects/piam/abrahao/GSCF_dk/magpie/"

# Paths to the files where scenarios are defined
# path_settings_remind contains the detailed configuration of the REMIND scenarios
# path_settings_coupled defines which runs will be started, coupling infos, and optimal gdx and report information that overrides path_settings_remind
path_settings_coupled <- paste0(path_remind,"config/scenario_config_coupled_SSPSDP.csv")
path_settings_remind  <- paste0(path_remind,"config/scenario_config_SSPSDP.csv")

# You can put a prefix in front of the names of your runs, this will turn e.g. "SSP2-Base" into "prefix_SSP2-Base".
# This allows storing results of multiple coupled runs (which have the same scenario names) in the same MAgPIE and REMIND output folders.
# !Currently not working for prefixes different from "C_". "C_" is hard-coded elsewhere!
prefix_runname <- "C_"

# If there are existing runs you would like to take the gdxes (REMIND) or reportings (REMIND or MAgPIE) from, provide the path here and the name prefix below.
# Note: the scenario names of the old runs have to be identical to the runs that are to be started. If they differ please provide the names of the old scenarios in the
# file that you specified on path_settings_coupled (scenario_config_coupled_xxx.csv).
path_remind_oldruns <- paste0(path_remind,"output/")
path_magpie_oldruns <- paste0(path_magpie,"output/")

# If you want the script to find gdxs or reports of older runs as starting point for new runs please
# provide the prefix of the old run names so the script can find them.
prefix_oldruns <-  "C_"

# number of coupling iterations
max_iterations <- 5

# Number of coupling iterations (before final iteration) in which MAgPIE uses higher n600 resolution.
# Until "max_iteration - n600_iterations" iteration MAgPIE runs with n200 resolution.
# Afterwards REMIND runs for "n600_iterations" iterations with results from higher resolution.
n600_iterations <- 0 # max_iterations

########################################################################################################
########################################################################################################
########################################################################################################

require(magclass)
require(lucode2)
require(gms)
require(remind2)
require(gtools) # required for mixedsort()
require(dplyr) # for filter, secelt, %>%

####################################################
############## F U N C T I O N S ###################
####################################################
.setgdxcopy <- function(needle,stack,new){
  # delete entries in stack that contain needle and append new
  matches <- grepl(needle,stack)
  out <- c(stack[!matches],new)
  return(out)
}

####################################################
##############  READ FROM COMMAND LINE #############
####################################################
readArgs("test")

####################################################
##############  READ SCENARIO FILES ################
####################################################
# Read-in the switches table, use first column as row names

scenarios_coupled <- read.csv2(path_settings_coupled, stringsAsFactors = FALSE, row.names=1, na.strings="")

# Read in

settings_remind <- read.csv2(path_settings_remind, stringsAsFactors = FALSE, row.names=1, na.strings="")

# Choose which scenarios to start: select rows according to "subset" and columns according to "select" (not used in the moment)
scenarios_coupled  <- subset(scenarios_coupled, subset=(start == "1"))

# some checks for title
if (any(nchar(rownames(scenarios_coupled)) > 75)) stop(paste0("These titles are too long: ", paste0(rownames(scenarios_coupled)[nchar(rownames(scenarios_coupled)) > 75], collapse = ", "), " – GAMS would not tolerate this, and quit working at a point where you least expect it. Stopping now."))
if (length(grep("\\.", rownames(scenarios_coupled))) > 0) stop(paste0("These titles contain dots: ", paste0(rownames(scenarios_coupled)[grep("\\.", rownames(scenarios_coupled))], collapse = ", "), " – GAMS would not tolerate this, and quit working at a point where you least expect it. Stopping now."))
if (length(grep("_$", rownames(scenarios_coupled))) > 0) stop(paste0("These titles end with _: ", paste0(rownames(scenarios_coupled)[grep("_$", rownames(scenarios_coupled))], collapse = ", "), ". This may lead start_bundle_coupled.R to select wrong gdx files. Stopping now."))


missing <- setdiff(rownames(scenarios_coupled),rownames(settings_remind))
if (!identical(missing, character(0))) {
  cat(paste0("The following scenarios are given in '",path_settings_coupled,"' but could not be found in '",path_settings_remind,"'\n"))
  cat(missing,sep="\n")
}

common <- intersect(rownames(settings_remind),rownames(scenarios_coupled))
if (!identical(common,character(0))) {
  cat("The following ",length(common)," scenarios will be started:\n")
  cat(common,sep="\n")
}

####################################################
######## PREPARE AND START COUPLED RUNS ############
####################################################
for(scen in common){
  cat(paste0("\n################################\nPreparing run ",scen,"\n"))

  runname      <- paste0(prefix_runname,scen)            # name of the run that is used for the folder names
  path_report  <- NULL                                   # sets the path to the report REMIND is started with in the first loop
  qos          <- scenarios_coupled[scen, "qos"]         # set the SLURM quality of service (priority/short/medium/...)
  if(is.null(qos)) qos <- "short"                        # if qos could not be found in scenarios_coupled use short

  start_iter <- 1 # iteration to start the coupling with

  # look whether there is already a REMIND run (check for old name if provided)
  if (!is.na(scenarios_coupled[scen, "oldrun"])) {
    needle <- scenarios_coupled[scen, "oldrun"]
  } else {
    needle <- scen
  }

  # Check for existing REMIND and MAgPIE runs and whether iteration can be continued from those (at least one REMIND iteration has to exist!)
  suche <- paste0(path_remind_oldruns,prefix_oldruns,needle,"-rem-*/fulldata.gdx")
  already_rem <- Sys.glob(suche)
  if(identical(already_rem,character(0))) cat("Nothing found for",suche,"\n")

  if (!identical(already_rem, character(0))) {
    # if there is an existing REMIND run, use its gdx for the run to be started
	  already_rem <- mixedsort(already_rem)[1]
	  settings_remind[scen, "path_gdx"] <- normalizePath(already_rem)
    cat(paste0("\nFound gdx here: ",normalizePath(already_rem),"\n"))
    iter_rem <- 0
    # is there a coupling iteration that could be continued?
    if(identical(paste0(path_remind,"output/"),path_remind_oldruns) && identical(prefix_runname,prefix_oldruns) && is.na(scenarios_coupled[scen, "oldrun"])) {
      # continue counting only if remind is started in the same directoy the gdxes are taken from
      iter_rem <- as.integer(sub(".*rem-(\\d.*)/.*","\\1",already_rem))
    }

    # is there already a MAgPIE run with this name?
    suche <- paste0(path_magpie_oldruns,prefix_oldruns,needle,"-mag-*/report.mif")
    already_mag <- Sys.glob(suche)
    if(identical(already_mag,character(0))) cat("Nothing found for",suche,"\n")
    iter_mag <- 0
    if (!identical(already_mag, character(0))) {
      already_mag <- mixedsort(already_mag)[1]
      path_report <- normalizePath(already_mag)
      cat(paste0("Found MAgPIE report here: ",normalizePath(already_mag),"\n"))
      iter_mag <- as.integer(sub(".*mag-(\\d.*)/.*","\\1",already_mag))
    }
    # decide whether to continue with REMIND or MAgPIE
    if (iter_rem > iter_mag) {
      # if only remind has finished an iteration -> start with magpie in this iteration using a REMIND report
      start_iter  <- iter_rem
      path_run    <- gsub("/fulldata.gdx","",already_rem)
      path_report <- Sys.glob(paste0(path_run,"/REMIND_generic_*"))[1] # take the first entry to ignore REMIND_generic_*_withoutPlus.mif
      if (is.na(path_report)) stop("There is a fulldata.gdx but no REMIND_generic_.mif in ",path_run,".\nPlease use Rscript output.R to produce it.")
      cat("Found REMIND report here: ",path_report,"\n")
      cat("Continuing with MAgPIE in iteration ",start_iter,"\n")
    } else {
      # if remind and magpie iteration is the same -> start next iteration with REMIND with or without MAgPIE report
      start_iter <- iter_rem + 1
    }
  }

  cat(paste0("Set start iteration to: ",start_iter,"\n"))

  # If a gdx is provided in scenario_config_coupled.csv use it instead of any previously found
  if (!is.na(scenarios_coupled[scen, "path_gdx"])) {
    settings_remind[scen, "path_gdx"] <- scenarios_coupled[scen, "path_gdx"]
    cat("Using gdx specified in\n  ",path_settings_coupled,"\n  ",settings_remind[scen, "path_gdx"],"\n")
  }

  # If provided replace the path to the MAgPIE report found automatically with path given in scenario_config_coupled.csv
  if (!is.na(scenarios_coupled[scen, "path_report"])) {
    path_report  <- scenarios_coupled[scen, "path_report"] # sets the path to the report REMIND is started with in the first loop
      cat("Replacing path to MAgPIE report with that one specified in\n  ",path_settings_coupled,"\n  ",scenarios_coupled[scen, "path_report"],"\n")
  }

  source(paste0(path_remind,"config/default.cfg")) # retrieve REMIND settings
  cfg_rem <- cfg
  rm(cfg)

  source(paste0(path_magpie,"config/default.cfg")) # retrieve MAgPIE settings
  cfg_mag <- cfg
  rm(cfg)

  # configure MAgPIE according to magpie_scen (scenario needs to be available in scenario_config.cfg)
  if(!is.null(scenarios_coupled[scen, "magpie_scen"])) cfg_mag <- setScenario(cfg_mag,c(trimws(unlist(strsplit(scenarios_coupled[scen, "magpie_scen"],split = ",|\\|"))),"coupling"),scenario_config=paste0(path_magpie,"config/scenario_config.csv"))
  cfg_mag <- check_config(cfg_mag, reference_file=paste0(path_magpie,"config/default.cfg"),modulepath = paste0(path_magpie,"modules/"))
  
  # GHG prices will be set to zero (in start_run() of MAgPIE) until and including the year specified here
  cfg_mag$mute_ghgprices_until <- scenarios_coupled[scen, "no_ghgprices_land_until"] 

  # if provided use ghg prices for land (MAgPIE) from a different REMIND run than the one MAgPIE runs coupled to
  path_mif_ghgprice_land <- NULL
  if ("path_mif_ghgprice_land" %in% names(scenarios_coupled)) {
    if (!is.na(scenarios_coupled[scen, "path_mif_ghgprice_land"])) {
        if (substr(scenarios_coupled[scen, "path_mif_ghgprice_land"], nchar(scenarios_coupled[scen, "path_mif_ghgprice_land"])-3, nchar(scenarios_coupled[scen, "path_mif_ghgprice_land"])) == ".mif") {
            # if real file is given (has ".mif" at the end) take it for path_mif_ghgprice_land
            path_mif_ghgprice_land <- scenarios_coupled[scen, "path_mif_ghgprice_land"]
        } else {
            # if no real file is given but a reference to another scenario (that has to run first) create path to the reference scenario
            path_mif_ghgprice_land <- paste0(path_remind,"output/",prefix_runname,scenarios_coupled[scen, "path_mif_ghgprice_land"],"-rem-",max_iterations,"/REMIND_generic_",prefix_runname,scenarios_coupled[scen, "path_mif_ghgprice_land"],"-rem-",max_iterations,".mif")
        }
        cfg_mag$path_to_report_ghgprices <- path_mif_ghgprice_land
    }
  }
  
  # How to provide the exogenous TC to MAgPIE:
  # Running MAgPIE with exogenous TC requires a path with exogenous TC. Using exo_indc_MAR17 the path is chosen via c13_tau_scen.
  # Using exo_JUN13 the path is given in the file modules/13_tc/exo_JUN13/input/tau_scenario.csv
  # This file can be generated (prior to all runs that use exogenous TC) using the following lines of code:
  #  require(magpie) # for tau function
  #  write.magpie(tau("/p/projects/htc/MagpieEmulator/r11356/magmaster/output/SSP2-SSP2-Ref-SPA0-endo-73-lessts/fulldata.gdx"),"modules/13_tc/exo_JUN13/input/tau_scenario.csv")
  #  Useful in case years mismatch:
  #  t  <- tau("/p/projects/htc/MagpieEmulator/r11356/magmaster/output/SSP2-SSP2-Ref-SPA0-endo-73/fulldata.gdx")
  #  y  <- c(seq(2005,2060,5),seq(2070,2110,10),2130,2150)
  #  tn <- time_interpolate(t,y,integrate_interpolated_years=TRUE,extrapolation_type = "constant")
  #  write.magpie(tn,"modules/13_tc/exo_JUN13/input/tau_scenario.csv")

  # Switch REMIND and MAgPIE to endogenous TC
  #cat("Setting MAgPIE to endogenous TC\n")
  #cfg_mag$gms$tc      <- "inputlib"
  #cfg_rem$gms$biomass <- "magpie_linear"

  # Configure Afforestation in MAgPIE
  # if (grepl("-aff760",scen)) {
  #    cat("Setting MAgPIE max_aff_area to 760\n")
  #    cfg_mag$gms$s32_max_aff_area <- 760
  #} else if (grepl("-aff900",scen)) {
  #    cat("Setting MAgPIE max_aff_area to 900\n")
  #    cfg_mag$gms$s32_max_aff_area <- 900
  #} else if (grepl("-affInf",scen)) {
  #    cat("Setting MAgPIE max_aff_area to Inf\n")
  #    cfg_mag$gms$s32_max_aff_area <- Inf
  #} else if (grepl("-cost2",scen)) {
  #    cat("Setting MAgPIE cprice_red_factor to 0.2\n")
  #    cfg_mag$gms$s56_cprice_red_factor <- 0.2
  #    cfg_mag$gms$s32_max_aff_area <- Inf
  #} else if (grepl("-cost3",scen)) {
  #    cat("Setting MAgPIE cprice_red_factor to 0.3\n")
  #    cfg_mag$gms$s56_cprice_red_factor <- 0.3
  #    cfg_mag$gms$s32_max_aff_area <- Inf
  #}

  #cfg$logoption  <- 2  # Have the log output written in a file (not on the screen)

  # Edit remind main model file, region settings and input data revision based on scenarios table, if cell non-empty
  for (switchname in intersect(c("model", "regionmapping", "inputRevision"), names(settings_remind))) {
    if ( ! is.na(settings_remind[scen, switchname] )) {
      cfg_rem[[switchname]] <- settings_remind[scen, switchname]
    }
  }

  # Edit switches in default.cfg based on scenarios table, if cell non-empty
  for (switchname in intersect(names(cfg_rem$gms), names(settings_remind))) {
    if ( ! is.na(settings_remind[scen, switchname] )) {
      cfg_rem$gms[[switchname]] <- settings_remind[scen, switchname]
    }
  }

  # Set description
  if ("description" %in% names(settings_remind) && ! is.na(settings_remind[scen, "description"])) {
    cfg_rem$description <- settings_remind[scen, "description"]
  } else {
    cfg_rem$description <- paste0("Coupled REMIND and MAgPIE run ", scen, " started by ", path_settings_remind, " and ", path_settings_coupled, ".")
  }

  # If provided replace gdx paths given in scenario_config with paths given in scenario_config_coupled
  if (!is.na(scenarios_coupled[scen, "path_gdx_bau"])) {
          settings_remind[scen, "path_gdx_bau"] <- scenarios_coupled[scen, "path_gdx_bau"]
          cat("Replacing gdx_bau information with those specified in\n  ",path_settings_coupled,"\n  ",settings_remind[scen, "path_gdx_bau"],"\n")
  }

  if (!is.na(scenarios_coupled[scen, "path_gdx_ref"])) {
	  settings_remind[scen, "path_gdx_ref"] <- scenarios_coupled[scen, "path_gdx_ref"]
	  cat("Replacing gdx_ref information with those specified in\n  ",path_settings_coupled,"\n  ",settings_remind[scen, "path_gdx_ref"],"\n")
  }

  # Create list of previously defined paths to gdxs
  gdxlist <- c(input.gdx     = settings_remind[scen, "path_gdx"], # eventually this was updated if older runs exists in this folder (see above)
               input_ref.gdx = settings_remind[scen, "path_gdx_ref"],
               input_bau.gdx = settings_remind[scen, "path_gdx_bau"])

  # Remove potential elements that contain ".gdx" and append gdxlist
  cfg_rem$files2export$start <- .setgdxcopy(".gdx",cfg_rem$files2export$start,gdxlist)

  # add table with information about runs that need the fulldata.gdx of the current run as input (will be further processed in start_coupled.R)
  cfg_rem$RunsUsingTHISgdxAsInput <- settings_remind[common,] %>%                 # select all scenarios that are going to be started
                                     select(contains("path_gdx_")) %>%            # select columns that have "path_gdx_" in their name
                                     filter(rowSums(. == scen, na.rm = TRUE) > 0) # select rows that have the current scenario in any column

  # immediately start run if it has a real gdx file (not a runname) given (last four letters are ".gdx") in path_gdx_ref or where this field is empty (NA)
  start_now <- (substr(settings_remind[scen,"path_gdx_ref"], nchar(settings_remind[scen,"path_gdx_ref"])-3, nchar(settings_remind[scen,"path_gdx_ref"])) == ".gdx"
               | is.na(settings_remind[scen,"path_gdx_ref"]))

  # perform the same checks for path_gdx_carbonprice and only start the run if both conditions are met
  has_carbonprice_path <- FALSE
  if ("path_gdx_carbonprice" %in% colnames(settings_remind)) { if (!is.na(settings_remind[scen,"path_gdx_carbonprice"])){
    has_carbonprice_path <- TRUE
  }}
  
  if (has_carbonprice_path) {
    cp_start_now <- (substr(settings_remind[scen,"path_gdx_carbonprice"], nchar(settings_remind[scen,"path_gdx_carbonprice"])-3, nchar(settings_remind[scen,"path_gdx_carbonprice"])) == ".gdx"
                | is.na(settings_remind[scen,"path_gdx_carbonprice"]))
    start_now <- start_now & cp_start_now
    cfg_rem$files2export$start['input_carbonprice.gdx'] <- settings_remind[scen,"path_gdx_carbonprice"]
  }

  if (!start_now) {
      # if no real file is given but a reference to another scenario (that has to run first) create path for input_ref and input_bau
      # using the scenario names given in the columns path_gdx_ref and path_gdx_ref in the REMIND standalone scenario config
      cfg_rem$files2export$start['input_ref.gdx'] <- paste0(path_remind,"output/",prefix_runname,settings_remind[scen,"path_gdx_ref"],"-rem-",max_iterations,"/fulldata.gdx")
      if (! grepl(".gdx", cfg_rem$files2export$start['input_bau.gdx'], fixed = TRUE)) {
        cfg_rem$files2export$start['input_bau.gdx'] <- paste0(path_remind,"output/",prefix_runname,settings_remind[scen,"path_gdx_bau"],"-rem-",max_iterations,"/fulldata.gdx")
      }

      # Do the same for "input.gdx"
      if ((! grepl(".gdx", cfg_rem$files2export$start['input.gdx'], fixed = TRUE)) & !is.na(cfg_rem$files2export$start['input.gdx'])) {
        cfg_rem$files2export$start['input.gdx'] <- paste0(path_remind,"output/",prefix_runname,settings_remind[scen,"path_gdx"],"-rem-",max_iterations,"/fulldata.gdx")
      }      

      # Also add path to carbon price gdx if given one 
      if (has_carbonprice_path) {
        cfg_rem$files2export$start['input_carbonprice.gdx'] <- paste0(path_remind,"output/",prefix_runname,settings_remind[scen,"path_gdx_carbonprice"],"-rem-",max_iterations,"/fulldata.gdx")
      }

      # If the preceding run has already finished (= its gdx file exist) start 
      # the current run immediately. This might be the case e.g. if you started
      # the NDC run in a first batch and now want to start the subsequent policy
      # runs by hand after the NDC has finished.
      if (file.exists(cfg_rem$files2export$start['input_ref.gdx'])) {
        start_now <- TRUE
      }

      # Don't start it if a carbon price path was set and the file does not exist yet
      if ("path_gdx_carbonprice" %in% colnames(settings_remind)) {
          if (!is.na(cfg_rem$files2export$start['input_carbonprice.gdx'])) {
              if (!file.exists(cfg_rem$files2export$start['input_carbonprice.gdx'])) {
                start_now <- FALSE
                cp_start_now <- FALSE
                #cat("Could not start",runname,"because I could not find",settings_remind[scen,"path_gdx_carbonprice"],"as specified in path_gdx_carbonprice!\n")
                }
          }
      }
  }

  save(path_remind,path_magpie,cfg_rem,cfg_mag,runname,max_iterations,start_iter,n600_iterations,path_report,qos,file=paste0(runname,".RData"))

  # Define colors for output
  red   <- "\033[0;31m"
  green <- "\033[0;32m"
  NC    <- "\033[0m"   # No Color

  # convert from logi to character so file.exists does not throw an error
  path_report <- as.character(path_report)

  cat("\nSUMMARY\n")
  cat("runname       :",runname,"\n")
  cat("QOS           :",qos,"\n")
  cat("start_iter    :",start_iter,"\n")
  cat("path_remind   : ",ifelse(dir.exists(path_remind),green,red), path_remind, NC, "\n",sep="")
  cat("path_magpie   : ",ifelse(dir.exists(path_magpie),green,red), path_magpie, NC, "\n",sep="")
  cat("remind gdx    : ",ifelse(file.exists(cfg_rem$files2export$start["input.gdx"]),green,red), cfg_rem$files2export$start["input.gdx"], NC, "\n",sep="")
  cat("ref_gdx       : ",ifelse(file.exists(cfg_rem$files2export$start["input_ref.gdx"]),green,red), cfg_rem$files2export$start["input_ref.gdx"], NC, "\n",sep="")
  cat("bau_gdx       : ",ifelse(file.exists(cfg_rem$files2export$start["input_bau.gdx"]),green,red), cfg_rem$files2export$start["input_bau.gdx"], NC, "\n",sep="")
  if(has_carbonprice_path) cat("carbonprice gdx : ",ifelse(file.exists(cfg_rem$files2export$start['input_carbonprice.gdx']),green,red), cfg_rem$files2export$start['input_carbonprice.gdx'], NC, "\n",sep="")
  if(!is.null(path_mif_ghgprice_land)) cat("ghg_price_mag : ",ifelse(file.exists(path_mif_ghgprice_land),green,red), path_mif_ghgprice_land, NC, "\n",sep="")
  cat("path_report   : ",ifelse(file.exists(path_report),green,red), path_report, NC, "\n",sep="")
  cat("no_ghgprices_land_until:",cfg_mag$mute_ghgprices_until,"\n")

  if (cfg_rem$gms$optimization == "nash" && cfg_rem$gms$cm_nash_mode == "parallel") {
    # for nash: set the number of CPUs per node to number of regions + 1
    nr_of_regions <- length(unique(read.csv2(cfg_rem$regionmapping)$RegionCode)) + 1
  } else {
    # for negishi: use only one CPU
    nr_of_regions <- 1
  }

  if (start_now){
      # Start SSP2-Base and SSP2-NDC as priority jobs since ALL subsequent runs depend on them
      #qos <- ifelse(grepl("SSP2-(NDC|Base)",runname),"priority","short")
      if (!exists("test")) system(paste0("sbatch --qos=",qos," --job-name=",runname," --output=",runname,".log --mail-type=END --comment=REMIND-MAgPIE --tasks-per-node=",nr_of_regions," --wrap=\"Rscript start_coupled.R coupled_config=",runname,".RData\""))
      else cat("Test mode: run NOT submitted to the cluster\n")
  } else {
     cat(paste0("Run ",runname," will start after preceding run ",prefix_runname,settings_remind[scen,"path_gdx_ref"]," has finished\n"))
     if (has_carbonprice_path) { if(!cp_start_now) {
      cat(paste0("Run ",runname," needs carbon prices from run ",prefix_runname,settings_remind[scen,"path_gdx_carbonprice"],"\n"))
     }}
  }
}
