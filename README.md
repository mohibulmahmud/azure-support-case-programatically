# azure-support-case-programatically
You can create azure support case programmatically using the scripts

# Browse all services
bash create-azure-support-ticket.sh --list-services

# Search by keyword
bash create-azure-support-ticket.sh --list-services --service "Cosmos"

# Interactive — prompts them to search and pick
bash create-azure-support-ticket.sh --interactive --config ticket.env
