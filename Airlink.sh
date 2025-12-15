#!/bin/bash

clear

# =========================
# Blue & Yellow color theme
# =========================
BLUE='\033[34m'
YELLOW='\033[33m'
BBLUE='\033[1;34m'
BYELLOW='\033[1;33m'
RESET='\033[0m'
INFO="${BLUE}[+]${RESET}"
WARN="${YELLOW}[!]${RESET}"

# ================
# Quiet log config
# ================
LOG_FILE="${HOME}/airlink_setup.log"
VERBOSE="${VERBOSE:-0}"  # set VERBOSE=1 to see command output

# Ensure cursor restored on any exit
restore_cursor() { tput cnorm 2>/dev/null || true; }
trap restore_cursor EXIT INT TERM

aash_logo() {
    echo -e "${BBLUE}  __  __ _      _                _ ${RESET}"
    echo -e "${BBLUE} |  \/  (_)    | |              | |${RESET}"
    echo -e "${BBLUE} | \  / |_  ___| |__   __ _  ___| |${RESET}"
    echo -e "${BBLUE} | |\/| | |/ __| '_ \ / _| |/ _ \ |${RESET}"
    echo -e "${BBLUE} | |  | | | (__| | | | (_| |  __/ |${RESET}"
    echo -e "${BBLUE} |_|  |_|_|\___|_| |_|\__,_|\___|_|${RESET}"
}

# Run a command quietly with spinner, log output, show only status
run() {
    local msg="$1"
    shift
    local cmd="$*"

    # Show task title
    printf "%b %s " "${INFO}" "${msg}"

    if [ "$VERBOSE" -eq 1 ]; then
        # No spinner in verbose to avoid garbled output
        bash -lc "$cmd"
        local rc=$?
        if [ $rc -ne 0 ]; then
            echo -e "\n${WARN} Failed (${rc}). See ${BYELLOW}${LOG_FILE}${RESET}"
            exit $rc
        fi
        echo -e "${BYELLOW}✓${RESET}"
        return 0
    fi

    # Quiet background execution with logging
    bash -lc "$cmd" >>"$LOG_FILE" 2>&1 &
    local pid=$!

    # Spinner loop (rotating / - \ |)
    local frames='/-\|'
    local i=0

    # Hide cursor during spinner
    tput civis 2>/dev/null || true

    # Spin while process is alive
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r%b %s %b%s%b" "${INFO}" "${msg}" "${YELLOW}" "${frames:$i:1}" "${RESET}"
        sleep 0.1
    done

    # Wait to get final exit code
    wait "$pid"
    local rc=$?

    # Clear spinner symbol and restore cursor
    printf "\r%b %s %b✓%b\n" "${INFO}" "${msg}" "${BYELLOW}" "${RESET}"
    tput cnorm 2>/dev/null || true

    if [ $rc -ne 0 ]; then
        echo -e "${WARN} Failed (${rc}). Check log: ${BYELLOW}${LOG_FILE}${RESET}"
        exit $rc
    fi
}

make_panel() {
    aash_logo

    run "Updating package index" "sudo apt-get -y -qq update"
    run "Installing base packages" "sudo apt-get -y -qq install curl software-properties-common git"

    run "Adding NodeJS 20 repo" "curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
    run "Installing NodeJS 20" "sudo apt-get -y -qq install nodejs"

    run "Cloning panel repository" "test -d panel || git clone --quiet https://github.com/StriderCraft315/panel.git"
    cd panel || exit

    run "Installing panel dependencies" "npm install --silent"
    run "Preparing environment file" "cp -n example.env .env || true"

    run "Running migrations" "npm run --silent migrate:dev"
    run "Building TypeScript" "npm run --silent build-ts"
    run "Seeding database" "npm run --silent seed"

    run "Installing PM2 globally" "npm install -g pm2 --silent"
    run "Starting panel with PM2" "pm2 --silent start dist/app.js --name panel"
    run "Saving PM2 process list" "pm2 --silent save"
    run "Setting up PM2 startup" "pm2 --silent startup"

    echo -e "${BYELLOW}Panel started on port 3000${RESET}"
    cd ..
}

make_node() {
    aash_logo

    run "Cloning daemon repository" "test -d daemon || git clone --quiet https://github.com/AirlinkLabs/daemon.git"
    cd daemon || exit

    run "Installing TypeScript globally" "npm install -g typescript --silent"
    run "Installing daemon dependencies" "npm install --silent"
    run "Preparing environment file" "test -f .env || cp example.env .env"
    run "Building daemon" "npm run --silent build"

    # Interactive configure with validation (execution output goes to log)
    while true; do
        echo -e "${BLUE}Example:${RESET} ${BYELLOW}npm run configure -- -- --panel \"http://localhost:3000\" --key \"**********\"${RESET}"
        printf "%b" "${BYELLOW}Paste your configure → ${RESET}"
        read -r nodecmd
        if [[ $nodecmd =~ ^[[:space:]]*npm[[:space:]]+run[[:space:]]+configure ]] \
           && [[ $nodecmd == *"--panel"* ]] \
           && [[ $nodecmd == *"--key"* ]]; then
            run "Configuring daemon" "$nodecmd"
            break
        else
            echo -e "${WARN} Wrong configure command! Please match the example format."
        fi
    done

    # Final step: start the node in dev mode (kept quiet unless VERBOSE=1)
    if [ "$VERBOSE" -eq 1 ]; then
        pm2 start npm --name "daemon" -- start
    else
        pm2 start npm --name "daemon" -- start >>"$LOG_FILE" 2>&1
    fi
}

start_all() {
    aash_logo
    run "Starting all services with PM2" "pm2 start all"
    echo -e "${BYELLOW}All PM2 services started${RESET}"
}

install_cloudflare() {
    aash_logo
    run "Adding Cloudflared GPG key" "sudo mkdir -p --mode=0755 /usr/share/keyrings && curl -fsS https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null"
    run "Adding Cloudflared repo" "echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >/novell"
    run "Installing Cloudflared" "sudo apt-get -y -qq update && sudo apt-get -y -qq install cloudflared"
    echo -e "${BYELLOW}Cloudflared installed.${RESET}"
}

install_playit() {
    aash_logo
    # Run Playit in the foreground with full output so the link works
    echo -e "${BYELLOW}Installing Playit tunnel (live output shown)...${RESET}"
    bash <(curl -s https://raw.githubusercontent.com/JishnuTheGamer/Vps/refs/heads/main/playit-2)
}

menu() {
    while true; do
        clear
        aash_logo

        echo ""
        echo -e "${BBLUE}==================== MAIN MENU ====================${RESET}"
        echo -e "${BLUE} [1]${RESET} ${BYELLOW}Make Panel${RESET}"
        echo -e "${BLUE} [2]${RESET} ${BYELLOW}Make Node${RESET}"
        echo -e "${BLUE} [3]${RESET} ${BYELLOW}Start again panel + node${RESET}"
        echo -e "${BLUE} [4]${RESET} ${BYELLOW}Install Cloudflare${RESET}"
        echo -e "${BLUE} [5]${RESET} ${BYELLOW}Playit Tunnel${RESET}"
        echo -e "${BBLUE} [0] Exit${RESET}"
        echo -e "${BBLUE}===================================================${RESET}"
        echo ""

        printf "%b" "${BYELLOW}Choose option → ${RESET}"
        read -r opt

        case $opt in
            1) make_panel ;;
            2) make_node ;;
            3) start_all ;;
            4) install_cloudflare ;;
            5) install_playit ;;
            0) exit ;;
            *) echo -e "${BYELLOW}Invalid option${RESET}"; sleep 1 ;;
        esac
        # Automatic return happens because this loop redraws the menu after each action
    done
}

menu
