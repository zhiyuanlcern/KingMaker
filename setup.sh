############################################################################################
# This script setups all dependencies necessary for making law executable                  #
############################################################################################

action() {

    # Check if law was already set up in this shell
    if ( [[ ! -z ${LAW_IS_SET_UP} ]] && [[ ! "$@" =~ "-f" ]] ); then
        echo "LAW was already set up in this shell. Please, use a new one."
        return 1
    fi

    # Check if current machine is an etp portal machine.
    PORTAL_LIST=("bms1.etp.kit.edu" "bms2.etp.kit.edu" "bms3.etp.kit.edu" "portal1.etp.kit.edu" "lxplus795.cern.ch")
    CURRENT_HOST=$(hostname --long)
    if [[ ! " ${PORTAL_LIST[*]} " =~ " ${CURRENT_HOST} " ]]; then  
        echo "Current host (${CURRENT_HOST}) not in list of allowed machines:"
        printf '%s\n' "${PORTAL_LIST[@]}"
        return 1
    else
        echo "Running on ${CURRENT_HOST}."
    fi

    #list of available analyses
    ANA_LIST=("KingMaker" "GPU_example" "ML_train")
    if [[ "$@" =~ "-l" ]]; then
        echo "Available analyses:"
        printf '%s\n' "${ANA_LIST[@]}"
        return 0
    fi

    # determine the directory of this file
    if [ ! -z "${ZSH_VERSION}" ]; then
        local THIS_FILE="${(%):-%x}"
    else
        local THIS_FILE="${BASH_SOURCE[0]}"
    fi

    local BASE_DIR="$( cd "$( dirname "${THIS_FILE}" )" && pwd )"

    _addpy() {
        [ ! -z "$1" ] && export PYTHONPATH="$1:${PYTHONPATH}"
    }

    _addbin() {
        [ ! -z "$1" ] && export PATH="$1:${PATH}"
    }


    ANA_NAME_GIVEN=$1

    #Determine analysis to be used. Default is first in list.
    if [[ -z "${ANA_NAME_GIVEN}" ]]; then
        echo "No analysis chosen. Please choose from:"
        printf '%s\n' "${ANA_LIST[@]}"
        return 1
    else
        #Check if given analysis is in list 
        if [[ ! " ${ANA_LIST[*]} " =~ " ${ANA_NAME_GIVEN} " ]] ; then 
            echo "Not a valid name. Allowed choices are:"
            printf '%s\n' "${ANA_LIST[@]}"
            return 1
        else
            echo "Using ${ANA_NAME_GIVEN} analysis." 
            export ANA_NAME="${ANA_NAME_GIVEN}"
        fi
    fi

    #Determine which environment to use based on the luigi.cfg file
    ENV_NAMES=($(grep '^ENV_NAME' lawluigi_configs/${ANA_NAME}_luigi.cfg | sed 's@ENV_NAME\s*=\s*\([^\s]*\)\s*@\1@g'))
    export ENV_NAMES_LIST=""
    for ENV_NAME in ${ENV_NAMES[@]}; do
        # Remember first env in lugi config file (usually in [DEFAULT])
        if [[ -z ${STARTING_ENV} ]]; then
            export STARTING_ENV=${ENV_NAME}
        fi

        #Check if necessary environment is present in cvmfs
        if [[ -d "/cvmfs/etp.kit.edu/LAW_envs/conda_envs/miniconda/envs/${ENV_NAME}" ]]; then
            echo "${ENV_NAME} environment found in cvmfs."
            CVMFS_ENV_PRESENT="True"
        else
            echo "${ENV_NAME} environment not found in cvmfs. Using conda."
            if ! command -v conda &> /dev/null; then
                # Install conda if necessary
                if [ ! -f "miniconda/bin/activate" ]; then
                    # Miniconda version used for all environments
                    MINICONDA_VERSION="Miniconda3-py39_4.10.3-Linux-x86_64"
                    echo "conda could not be found, installing conda ..."
                    echo "More information can be found in"
                    echo "https://docs.conda.io/projects/conda/en/latest/user-guide/install/index.html"
                    curl -O https://repo.anaconda.com/miniconda/${MINICONDA_VERSION}.sh
                    bash ${MINICONDA_VERSION}.sh -b -p miniconda
                    rm -f ${MINICONDA_VERSION}.sh
                fi
                # source base env of conda
                source miniconda/bin/activate base
            fi

            # check if correct Conda env is running
            if [ "${CONDA_DEFAULT_ENV}" != "${ENV_NAME}" ]; then
                if [ -d "miniconda/envs/${ENV_NAME}" ]; then
                    echo  "${ENV_NAME} env found using conda."
                else
                    # Create conda env from yaml file if necessary
                    echo "Creating ${ENV_NAME} env from conda_environments/${ENV_NAME}_env.yml..."
                    if [[ ! -f "conda_environments/${ENV_NAME}_env.yml" ]]; then
                        echo "conda_environments/${ENV_NAME}_env.yml not found. Unable to create environment."
                        return 1
                    fi
                    conda env create -f conda_environments/${ENV_NAME}_env.yml -n ${ENV_NAME}
                    echo  "${ENV_NAME} env built using conda."
                fi
            fi

            # create conda tarball if env not in cvmfs and it if it doesn't already exist
            if [ ! -f "tarballs/conda_envs/${ENV_NAME}.tar.gz" ]; then
                # IMPORTANT: environments have to be named differently with each change
                #            as chaching prevents a clean overwrite of existing files
                echo "Creating ${ENV_NAME}.tar.gz"
                mkdir -p "tarballs/conda_envs"
                conda activate ${ENV_NAME}
                conda pack -n ${ENV_NAME} --output tarballs/conda_envs/${ENV_NAME}.tar.gz
                conda deactivate
            fi
            CVMFS_ENV_PRESENT="False"
        fi

        # Remember status of starting-env
        if [[ "${ENV_NAME}" == "${STARTING_ENV}" ]]; then
            CVMFS_ENV_PRESENT_START=${CVMFS_ENV_PRESENT}
        fi
        # Create list of envs and their status to be later parsed by python
        #   Example: 'env1;True,env2;False,env3;False'
        # ENV_NAMES_LIST is used by the processor/framework.py to determine whether the environments are present in cvmfs
        ENV_NAMES_LIST+="${ENV_NAME},${CVMFS_ENV_PRESENT};"
    done
    # Actvate starting-env
    if [[ "${CVMFS_ENV_PRESENT_START}" == "True" ]]; then
        echo "Activating starting-env ${STARTING_ENV} from cvmfs."
        source /cvmfs/etp.kit.edu/LAW_envs/conda_envs/miniconda/bin/activate ${STARTING_ENV}
    else
        echo "Activating starting-env ${STARTING_ENV} from conda."
        conda activate ${STARTING_ENV}
    fi

    #Set up other dependencies based on analysis
    ############################################
    case ${ANA_NAME} in
        KingMaker)
            echo "Setting up CROWN ..."
            # Due to frequent updates CROWN is not set up as a submodule
            if [ ! -d CROWN ]; then
                git clone --recursive git@github.com:KIT-CMS/CROWN
            fi
            if [ -z "$(ls -A sample_database)" ]; then
                git submodule update --init --recursive -- sample_database
            fi
            ;;
        ML_train)
            echo "Setting up ML-scripts ..."
            if [ -z "$(ls -A sm-htt-analysis)" ]; then
                git submodule update --init --recursive -- sm-htt-analysis
            fi
            ;;
        *)
            ;;
    esac
    ############################################

    # Check is law was cloned, and set it up if not
    if [ -z "$(ls -A law)" ]; then
        git submodule update --init --recursive -- law
    fi

    echo "Setting up Luigi/Law ..."
    export LAW_HOME="${BASE_DIR}/.law/${ANA_NAME}"
    export LAW_CONFIG_FILE="${BASE_DIR}/lawluigi_configs/${ANA_NAME}_law.cfg"
    export LUIGI_CONFIG_PATH="${BASE_DIR}/lawluigi_configs/${ANA_NAME}_luigi.cfg"
    export ANALYSIS_PATH="${BASE_DIR}"
    export ANALYSIS_DATA_PATH="${ANALYSIS_PATH}/data"

    # law
    _addpy "${BASE_DIR}/law"
    _addbin "${BASE_DIR}/law/bin"
    source "$( law completion )"

    # tasks
    _addpy "${BASE_DIR}/processor"
    _addpy "${BASE_DIR}/processor/tasks"

    # add voms proxy path
    export X509_USER_PROXY=$(voms-proxy-info -path)
    # first check if the user already has a luigid scheduler running
    # start a luidigd scheduler if there is one already running
    if [ -z "$(pgrep -u ${USER} -f luigid)" ]; then
        echo "Starting Luigi scheduler... using a random port"
        while
            LUIGIPORT=$(shuf -n 1 -i 49152-65535)
            netstat -atun | grep -q "$LUIGIPORT"
        do
            continue
        done
        luigid --background --logdir logs --state-path luigid_state.pickle --port=$LUIGIPORT
        echo "Luigi scheduler started on port $LUIGIPORT, setting LUIGIPORT to $LUIGIPORT"
    else
        # first get the PID
        LUIGIPID=$(pgrep -u ${USER} -f luigid)
        # now get the luigid port that the scheduler is using and set the LUIGIPORT variable
        LUIGIPORT=$(cat /proc/${LUIGIPID}/cmdline | sed -e "s/\x00/ /g" | cut -d "=" -f2)
        echo "Luigi scheduler already running on port ${LUIGIPORT}, setting LUIGIPORT to ${LUIGIPORT}"
    fi

    # Create law index for analysis if not previously done
    if [[ ! -f "${LAW_HOME}/index" ]]; then
        law index --verbose
    fi

    export LAW_IS_SET_UP="True"
}
action "$@"
