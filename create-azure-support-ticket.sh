#!/usr/bin/env bash
###############################################################################
# create-azure-support-ticket.sh
#
# Programmatically creates an Azure Support ticket via Azure CLI.
#
# Prerequisites:
#   1. Authenticated session (az login)
#   2. "Support Request Contributor" role on the target subscription
#   3. Microsoft.Support resource provider registered
#   4. Azure CLI 'support' extension installed:
#        az extension add --name support --upgrade
#
# Usage:
#   ./create-azure-support-ticket.sh                         # interactive defaults
#   ./create-azure-support-ticket.sh --config ticket.env     # load from env file
#   ./create-azure-support-ticket.sh \
#       --service "Azure Monitor" \
#       --problem "Metrics" \
#       --severity moderate \
#       --title "Metrics gap on prod DB" \
#       --description "No metrics since 14:00 UTC" \
#       --first-name Mohibul \
#       --last-name Mahmud \
#       --email mohibul@microsoft.com
#
# Author:  Mohibul Mahmud
# Version: 1.0.0
# Date:    2026-03-30
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# DEFAULTS (override via flags, env vars, or config file)
#
# Note: Required fields are NOT pre-initialized here so that config file
# values can populate them. Defaults are applied AFTER config loading.
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
CONFIG_FILE=""
MODE="create"

# These will be set after config loading via apply_defaults()
# Required: TICKET_TITLE, TICKET_DESCRIPTION, CONTACT_FIRST_NAME,
#           CONTACT_LAST_NAME, CONTACT_EMAIL
# Optional with defaults: TICKET_SERVICE, TICKET_PROBLEM, TICKET_SEVERITY,
#           CONTACT_METHOD, CONTACT_TIMEZONE, CONTACT_COUNTRY, CONTACT_LANGUAGE,
#           ADVANCED_DIAGNOSTIC_CONSENT

# ─────────────────────────────────────────────────────────────────────────────
# COLORS & HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "[DEBUG] $*" || true; }

# Apply defaults for optional fields AFTER config + args are loaded
apply_defaults() {
    : "${TICKET_SERVICE:=Azure Monitor}"
    : "${TICKET_PROBLEM:=Metrics}"
    : "${TICKET_SEVERITY:=minimal}"
    : "${TICKET_SUBSCRIPTION:=}"
    : "${CONTACT_METHOD:=email}"
    : "${CONTACT_TIMEZONE:=Eastern Standard Time}"
    : "${CONTACT_COUNTRY:=CAN}"
    : "${CONTACT_LANGUAGE:=en-us}"
    : "${ADVANCED_DIAGNOSTIC_CONSENT:=Yes}"
    # Required fields: no defaults — validate_inputs will catch them
    : "${TICKET_TITLE:=}"
    : "${TICKET_DESCRIPTION:=}"
    : "${CONTACT_FIRST_NAME:=}"
    : "${CONTACT_LAST_NAME:=}"
    : "${CONTACT_EMAIL:=}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required (via flags or env vars):
  --title TEXT                Ticket title
  --description TEXT          Ticket description
  --first-name NAME          Contact first name
  --last-name NAME           Contact last name
  --email ADDRESS             Contact email

Optional:
  --service NAME              Azure service display name  [default: Azure Monitor]
  --problem KEYWORD           Problem classification keyword [default: Metrics]
  --severity LEVEL            minimal|moderate|highestcriticalimpact|critical [default: minimal]
  --subscription ID           Target subscription ID [default: current]
  --contact-method METHOD     email|phone [default: email]
  --timezone TZ               Contact timezone [default: Eastern Standard Time]
  --country CODE              Contact country code [default: CAN]
  --language LANG             Contact language [default: en-us]
  --consent Yes|No            Advanced diagnostic consent [default: Yes]
  --config FILE               Source an env file for parameters
  --dry-run                   Validate and print command without executing
  --verbose                   Enable debug output
  -h, --help                  Show this help

Discovery:
  --list-services             List all Azure services (filterable with --service keyword)
  --list-problems             List problem classifications for a service (use with --service)

Interactive:
  --interactive, -i           Step-by-step guided ticket creation

Environment Variables:
  All flags map to TICKET_* or CONTACT_* env vars (see script header).

Examples:
  # Minimal invocation with required flags
  $(basename "$0") --title "Alert gap" --description "No data" \\
      --first-name Mohibul --last-name Mahmud --email m@contoso.com

  # Load from config file
  $(basename "$0") --config prod-ticket.env

  # Dry-run for validation
  $(basename "$0") --config prod-ticket.env --dry-run --verbose
EOF
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)          TICKET_SERVICE="$2";          shift 2 ;;
            --problem)          TICKET_PROBLEM="$2";          shift 2 ;;
            --severity)         TICKET_SEVERITY="$2";         shift 2 ;;
            --title)            TICKET_TITLE="$2";            shift 2 ;;
            --description)      TICKET_DESCRIPTION="$2";      shift 2 ;;
            --subscription)     TICKET_SUBSCRIPTION="$2";     shift 2 ;;
            --first-name)       CONTACT_FIRST_NAME="$2";      shift 2 ;;
            --last-name)        CONTACT_LAST_NAME="$2";       shift 2 ;;
            --email)            CONTACT_EMAIL="$2";           shift 2 ;;
            --contact-method)   CONTACT_METHOD="$2";          shift 2 ;;
            --timezone)         CONTACT_TIMEZONE="$2";        shift 2 ;;
            --country)          CONTACT_COUNTRY="$2";         shift 2 ;;
            --language)         CONTACT_LANGUAGE="$2";        shift 2 ;;
            --consent)          ADVANCED_DIAGNOSTIC_CONSENT="$2"; shift 2 ;;
            --config)           CONFIG_FILE="$2";             shift 2 ;;
            --dry-run)          DRY_RUN=true;                 shift ;;
            --verbose)          VERBOSE=true;                 shift ;;
            --list-services)    MODE="list-services";         shift ;;
            --list-problems)    MODE="list-problems";         shift ;;
            --interactive|-i)   MODE="interactive";           shift ;;
            -h|--help)          usage ;;
            *)                  err "Unknown option: $1"; usage ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# PREREQUISITE CHECKS
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    log "Running preflight checks..."

    # 1. Azure CLI installed
    if ! command -v az &>/dev/null; then
        err "Azure CLI (az) not found. Install: https://aka.ms/installazurecli"
        exit 1
    fi
    ok "Azure CLI found: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null)"

    # 2. Authenticated session
    if ! az account show &>/dev/null; then
        err "Not authenticated. Run 'az login' first."
        exit 1
    fi
    ok "Authenticated as: $(az account show --query user.name -o tsv)"

    # 3. Set subscription if specified
    if [[ -n "$TICKET_SUBSCRIPTION" ]]; then
        log "Setting subscription to: $TICKET_SUBSCRIPTION"
        az account set --subscription "$TICKET_SUBSCRIPTION"
    fi
    ok "Subscription: $(az account show --query '{name:name, id:id}' -o tsv)"

    # 4. Support extension
    if ! az extension show --name support &>/dev/null; then
        warn "'support' extension not found. Installing..."
        az extension add --name support --upgrade --yes
    fi
    ok "Support extension: $(az extension show --name support --query version -o tsv)"

    # 5. Resource provider
    local rp_state
    rp_state=$(az provider show --namespace Microsoft.Support --query registrationState -o tsv 2>/dev/null || echo "Unknown")
    if [[ "$rp_state" != "Registered" ]]; then
        warn "Microsoft.Support provider state: $rp_state. Registering..."
        az provider register --namespace Microsoft.Support --wait
    fi
    ok "Microsoft.Support provider: Registered"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: DISCOVERY — resolve live Service & Problem Classification IDs
# ─────────────────────────────────────────────────────────────────────────────
discover_ids() {
    log "Phase 1: Discovering Service and Problem Classification IDs..."

    # --- Service ID ---
    # Use exact match first; fall back to contains()
    SERVICE_ID=$(az support services list \
        --query "[?displayName=='${TICKET_SERVICE}'].name" -o tsv 2>/dev/null)

    if [[ -z "$SERVICE_ID" ]]; then
        debug "Exact match failed for '${TICKET_SERVICE}', trying partial match..."
        SERVICE_ID=$(az support services list \
            --query "[?contains(displayName, '${TICKET_SERVICE}')].{name:name, display:displayName}" \
            -o tsv 2>/dev/null | head -n 1 | cut -f1)
    fi

    if [[ -z "$SERVICE_ID" ]]; then
        err "Could not find Azure service matching: '${TICKET_SERVICE}'"
        err "Available services:"
        az support services list --query "[].displayName" -o tsv | head -20
        exit 1
    fi
    ok "Service ID: $SERVICE_ID (${TICKET_SERVICE})"

    # --- Problem Classification ID ---
    CLASSIFICATION_ID=$(az support services problem-classifications list \
        --service-name "$SERVICE_ID" \
        --query "[?contains(displayName, '${TICKET_PROBLEM}')].id" -o tsv 2>/dev/null | head -n 1)

    if [[ -z "$CLASSIFICATION_ID" ]]; then
        err "Could not find problem classification matching: '${TICKET_PROBLEM}'"
        err "Available classifications for service '$SERVICE_ID':"
        az support services problem-classifications list \
            --service-name "$SERVICE_ID" \
            --query "[].displayName" -o tsv
        exit 1
    fi
    ok "Classification ID: $CLASSIFICATION_ID (${TICKET_PROBLEM})"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
validate_inputs() {
    log "Validating required inputs..."

    local missing=()
    [[ -z "$TICKET_TITLE" ]]       && missing+=("--title")
    [[ -z "$TICKET_DESCRIPTION" ]] && missing+=("--description")
    [[ -z "$CONTACT_FIRST_NAME" ]] && missing+=("--first-name")
    [[ -z "$CONTACT_LAST_NAME" ]]  && missing+=("--last-name")
    [[ -z "$CONTACT_EMAIL" ]]      && missing+=("--email")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required parameters: ${missing[*]}"
        echo ""
        usage
    fi

    # Severity validation
    local valid_severities=("minimal" "moderate" "highestcriticalimpact" "critical")
    local sev_valid=false
    for s in "${valid_severities[@]}"; do
        [[ "$TICKET_SEVERITY" == "$s" ]] && sev_valid=true && break
    done
    if [[ "$sev_valid" == "false" ]]; then
        err "Invalid severity: '$TICKET_SEVERITY'"
        err "Valid values: ${valid_severities[*]}"
        exit 1
    fi

    # Consent validation
    if [[ "$ADVANCED_DIAGNOSTIC_CONSENT" != "Yes" && "$ADVANCED_DIAGNOSTIC_CONSENT" != "No" ]]; then
        err "Invalid --consent value: '$ADVANCED_DIAGNOSTIC_CONSENT' (must be Yes or No)"
        exit 1
    fi

    ok "All inputs validated"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: TICKET CREATION
# ─────────────────────────────────────────────────────────────────────────────
create_ticket() {
    local ticket_name="SupportTicket-$(date +%Y%m%d%H%M%S)"

    log "Phase 3: Creating support ticket..."
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  Ticket Summary                                        │"
    echo "  ├─────────────────────────────────────────────────────────┤"
    printf "  │  %-14s %-42s│\n" "Name:"        "$ticket_name"
    printf "  │  %-14s %-42s│\n" "Title:"       "${TICKET_TITLE:0:42}"
    printf "  │  %-14s %-42s│\n" "Severity:"    "$TICKET_SEVERITY"
    printf "  │  %-14s %-42s│\n" "Service:"     "$TICKET_SERVICE"
    printf "  │  %-14s %-42s│\n" "Problem:"     "$TICKET_PROBLEM"
    printf "  │  %-14s %-42s│\n" "Contact:"     "$CONTACT_FIRST_NAME $CONTACT_LAST_NAME"
    printf "  │  %-14s %-42s│\n" "Email:"       "$CONTACT_EMAIL"
    printf "  │  %-14s %-42s│\n" "Consent:"     "$ADVANCED_DIAGNOSTIC_CONSENT"
    echo "  └─────────────────────────────────────────────────────────┘"
    echo ""

    local cmd=(
        az support in-subscription tickets create
        --ticket-name "$ticket_name"
        --title "$TICKET_TITLE"
        --description "$TICKET_DESCRIPTION"
        --severity "$TICKET_SEVERITY"
        --problem-classification "$CLASSIFICATION_ID"
        --contact-first-name "$CONTACT_FIRST_NAME"
        --contact-last-name "$CONTACT_LAST_NAME"
        --contact-method "$CONTACT_METHOD"
        --contact-email "$CONTACT_EMAIL"
        --contact-timezone "$CONTACT_TIMEZONE"
        --contact-country "$CONTACT_COUNTRY"
        --contact-language "$CONTACT_LANGUAGE"
        --advanced-diagnostic-consent "$ADVANCED_DIAGNOSTIC_CONSENT"
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN — command that would execute:"
        echo ""
        printf '  %s \\\n' "${cmd[@]:0:${#cmd[@]}-1}"
        echo "    ${cmd[-1]}"
        echo ""
        log "No ticket created. Remove --dry-run to execute."
        return 0
    fi

    log "Executing ticket creation..."
    local result
    if result=$("${cmd[@]}" -o json 2>&1); then
        ok "Ticket created successfully!"
        echo ""
        echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"

        # Extract ticket ID for follow-up
        local ticket_id
        ticket_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','N/A'))" 2>/dev/null || echo "N/A")
        echo ""
        ok "Ticket ID: $ticket_id"
        log "View in portal: https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade"
    else
        err "Ticket creation failed:"
        echo "$result" >&2
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DISCOVERY MODE — list services and problem classifications
# ─────────────────────────────────────────────────────────────────────────────
list_services() {
    local filter="${TICKET_SERVICE:-}"

    if [[ -n "$filter" && "$filter" != "Azure Monitor" ]]; then
        log "Searching Azure services matching: '$filter'"
        echo ""
        az support services list \
            --query "[?contains(displayName, '${filter}')].{Name:name, DisplayName:displayName}" \
            -o table
    else
        log "Listing all Azure services..."
        echo ""
        az support services list \
            --query "[].{Name:name, DisplayName:displayName}" \
            -o table
    fi

    echo ""
    log "Tip: Use --list-problems --service \"<exact name>\" to see problem classifications."
}

list_problems() {
    local service_filter="${TICKET_SERVICE:-Azure Monitor}"

    log "Finding service: '$service_filter'"

    # Resolve service ID (exact match first, then partial)
    local svc_id
    svc_id=$(az support services list \
        --query "[?displayName=='${service_filter}'].name" -o tsv 2>/dev/null)

    if [[ -z "$svc_id" ]]; then
        svc_id=$(az support services list \
            --query "[?contains(displayName, '${service_filter}')].name" \
            -o tsv 2>/dev/null | head -n 1)
    fi

    if [[ -z "$svc_id" ]]; then
        err "No service found matching: '$service_filter'"
        log "Run --list-services to see available services."
        exit 1
    fi

    local svc_display
    svc_display=$(az support services show --service-name "$svc_id" \
        --query "displayName" -o tsv 2>/dev/null || echo "$service_filter")

    log "Problem classifications for: $svc_display"
    echo ""
    az support services problem-classifications list \
        --service-name "$svc_id" \
        --query "[].{ID:name, DisplayName:displayName}" \
        -o table

    echo ""
    log "Use the DisplayName value as your --problem keyword."
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MODE — guided step-by-step ticket creation
# ─────────────────────────────────────────────────────────────────────────────
prompt_input() {
    local var_name="$1" prompt_text="$2" default_val="${3:-}"
    local input

    if [[ -n "$default_val" ]]; then
        printf "${CYAN}%s${NC} [${GREEN}%s${NC}]: " "$prompt_text" "$default_val"
    else
        printf "${CYAN}%s${NC}: " "$prompt_text"
    fi
    read -r input
    input="${input:-$default_val}"

    # Use printf -v to assign to the variable name
    printf -v "$var_name" '%s' "$input"
}

select_from_list() {
    local var_name="$1"
    shift
    local options=("$@")
    local count=${#options[@]}

    for i in "${!options[@]}"; do
        printf "  ${YELLOW}%3d${NC}) %s\n" "$((i + 1))" "${options[$i]}"
    done
    echo ""

    local selection
    while true; do
        printf "${CYAN}Enter number (1-%d)${NC}: " "$count"
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= count )); then
            printf -v "$var_name" '%s' "${options[$((selection - 1))]}"
            return 0
        fi
        err "Invalid selection. Please enter a number between 1 and $count."
    done
}

interactive_mode() {
    echo ""
    echo "  ╔═════════════════════════════════════════════════════════╗"
    echo "  ║          Interactive Ticket Creation Wizard             ║"
    echo "  ╚═════════════════════════════════════════════════════════╝"
    echo ""

    # ── Step 1: Search and select Azure Service ──────────────────────────
    log "Step 1 of 6: Select Azure Service"
    echo ""
    local search_term
    printf "${CYAN}Search for a service (e.g. Monitor, Kubernetes, App Service)${NC}: "
    read -r search_term

    echo ""
    log "Searching for '$search_term'..."
    echo ""

    # Get matching services into arrays
    local svc_names=()
    local svc_ids=()
    while IFS=$'\t' read -r sid sname; do
        [[ -n "$sid" ]] && svc_ids+=("$sid") && svc_names+=("$sname")
    done < <(az support services list \
        --query "[?contains(displayName, '${search_term}')].{id:name, name:displayName}" \
        -o tsv 2>/dev/null)

    if [[ ${#svc_names[@]} -eq 0 ]]; then
        err "No services found matching '$search_term'."
        echo ""
        log "Try a broader keyword. Examples: Monitor, Kubernetes, SQL, Storage, App"
        exit 1
    fi

    echo "  Found ${#svc_names[@]} service(s):"
    echo ""
    local selected_svc
    select_from_list selected_svc "${svc_names[@]}"

    # Find the matching service ID
    for i in "${!svc_names[@]}"; do
        if [[ "${svc_names[$i]}" == "$selected_svc" ]]; then
            SERVICE_ID="${svc_ids[$i]}"
            break
        fi
    done
    TICKET_SERVICE="$selected_svc"
    ok "Selected: $TICKET_SERVICE"
    echo ""

    # ── Step 2: Select Problem Classification ────────────────────────────
    log "Step 2 of 6: Select Problem Classification"
    echo ""
    log "Loading problem classifications for $TICKET_SERVICE..."
    echo ""

    local prob_names=()
    local prob_ids=()
    while IFS=$'\t' read -r pid pname; do
        [[ -n "$pid" ]] && prob_ids+=("$pid") && prob_names+=("$pname")
    done < <(az support services problem-classifications list \
        --service-name "$SERVICE_ID" \
        --query "[].{id:id, name:displayName}" \
        -o tsv 2>/dev/null)

    if [[ ${#prob_names[@]} -eq 0 ]]; then
        err "No problem classifications found for $TICKET_SERVICE."
        exit 1
    fi

    # Allow filtering if too many results
    if [[ ${#prob_names[@]} -gt 20 ]]; then
        echo "  ${#prob_names[@]} classifications found. Filter to narrow down."
        echo ""
        local prob_filter
        printf "${CYAN}Filter keyword (or press Enter to see all)${NC}: "
        read -r prob_filter

        if [[ -n "$prob_filter" ]]; then
            local filtered_names=()
            local filtered_ids=()
            for i in "${!prob_names[@]}"; do
                if [[ "${prob_names[$i],,}" == *"${prob_filter,,}"* ]]; then
                    filtered_names+=("${prob_names[$i]}")
                    filtered_ids+=("${prob_ids[$i]}")
                fi
            done

            if [[ ${#filtered_names[@]} -eq 0 ]]; then
                warn "No match for '$prob_filter'. Showing all."
                echo ""
            else
                prob_names=("${filtered_names[@]}")
                prob_ids=("${filtered_ids[@]}")
                echo ""
                echo "  Found ${#prob_names[@]} matching classification(s):"
                echo ""
            fi
        fi
    fi

    local selected_prob
    select_from_list selected_prob "${prob_names[@]}"

    # Find the matching classification ID
    for i in "${!prob_names[@]}"; do
        if [[ "${prob_names[$i]}" == "$selected_prob" ]]; then
            CLASSIFICATION_ID="${prob_ids[$i]}"
            break
        fi
    done
    TICKET_PROBLEM="$selected_prob"
    ok "Selected: $TICKET_PROBLEM"
    echo ""

    # ── Step 3: Severity ─────────────────────────────────────────────────
    log "Step 3 of 6: Select Severity"
    echo ""
    local severities=("minimal — General guidance" "moderate — Moderate business impact" "highestcriticalimpact — Serious business impact" "critical — Critical business impact (24/7)")
    local selected_sev
    select_from_list selected_sev "${severities[@]}"
    TICKET_SEVERITY="${selected_sev%% —*}"
    ok "Severity: $TICKET_SEVERITY"
    echo ""

    # ── Step 4: Title & Description ──────────────────────────────────────
    log "Step 4 of 6: Describe the Issue"
    echo ""
    prompt_input TICKET_TITLE "Ticket title (short summary)" "${TICKET_TITLE:-}"
    echo ""
    prompt_input TICKET_DESCRIPTION "Description (detailed explanation)" "${TICKET_DESCRIPTION:-}"
    echo ""

    # ── Step 5: Contact Info ─────────────────────────────────────────────
    log "Step 5 of 6: Contact Information"
    echo ""
    prompt_input CONTACT_FIRST_NAME "First name" "${CONTACT_FIRST_NAME:-}"
    prompt_input CONTACT_LAST_NAME "Last name" "${CONTACT_LAST_NAME:-}"
    prompt_input CONTACT_EMAIL "Email" "${CONTACT_EMAIL:-}"
    prompt_input CONTACT_TIMEZONE "Timezone" "${CONTACT_TIMEZONE:-Eastern Standard Time}"
    prompt_input CONTACT_COUNTRY "Country code" "${CONTACT_COUNTRY:-CAN}"
    echo ""

    # ── Step 6: Confirm & Create ─────────────────────────────────────────
    log "Step 6 of 6: Review & Confirm"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  Ticket Summary                                            │"
    echo "  ├─────────────────────────────────────────────────────────────┤"
    printf "  │  %-14s %-46s│\n" "Service:"    "${TICKET_SERVICE:0:46}"
    printf "  │  %-14s %-46s│\n" "Problem:"    "${TICKET_PROBLEM:0:46}"
    printf "  │  %-14s %-46s│\n" "Severity:"   "$TICKET_SEVERITY"
    printf "  │  %-14s %-46s│\n" "Title:"      "${TICKET_TITLE:0:46}"
    printf "  │  %-14s %-46s│\n" "Contact:"    "$CONTACT_FIRST_NAME $CONTACT_LAST_NAME"
    printf "  │  %-14s %-46s│\n" "Email:"      "$CONTACT_EMAIL"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""

    local confirm
    printf "${YELLOW}Submit this ticket? (y/n/dry-run)${NC}: "
    read -r confirm

    case "${confirm,,}" in
        y|yes)
            log "Creating ticket..."
            create_ticket
            ;;
        d|dry|dry-run)
            DRY_RUN=true
            create_ticket
            ;;
        *)
            warn "Cancelled. No ticket created."
            exit 0
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         Azure Support Ticket — Automated Creation           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # 1. First pass: parse args to capture --config (and other flags)
    parse_args "$@"

    # 2. Source config file if specified (fills in any unset vars)
    if [[ -n "${CONFIG_FILE:-}" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            log "Loading config from: $CONFIG_FILE"
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
        else
            err "Config file not found: $CONFIG_FILE"
            exit 1
        fi
        # 3. Re-parse args so CLI flags override config file values
        parse_args "$@"
    fi

    # 4. Apply defaults for any remaining unset optional fields
    apply_defaults

    # 5. Route based on mode
    case "$MODE" in
        list-services)
            list_services
            exit 0
            ;;
        list-problems)
            list_problems
            exit 0
            ;;
        interactive)
            preflight
            interactive_mode
            ;;
        create)
            validate_inputs
            preflight
            discover_ids
            create_ticket
            ;;
    esac

    echo ""
    ok "Done."
}

main "$@"
