#!/usr/bin/env bash
# usage: bash show_container_distribution.sh $PROJECT_ID $ENV

# Auto-detect CLI: prefer upsun, fall back to platform
if command -v upsun >/dev/null 2>&1; then
    CMD="upsun"
elif command -v platform >/dev/null 2>&1; then
    CMD="platform"
else
    echo "Error: neither 'upsun' nor 'platform' CLI found. Please install one of them." >&2
    exit 1
fi

PROJECT_ID=""

if [ $# -eq 0 ]; then
    # try finding the .upsun/local or .platform/local folder
    PROJECT_ID=$(grep -F 'id:' ".upsun/local/project.yaml" 2>/dev/null | cut -d' ' -f2)

    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID=$(grep -F 'id:' ".platform/local/project.yaml" 2>/dev/null | cut -d' ' -f2)
    fi

    if [ -z "$PROJECT_ID" ]; then
        echo "Error: no project ID found. Please supply the project_id as parameter:" >&2
        echo "" >&2
        echo "Usage: " >&2
        echo "  bash show_container_distribution.sh \$PROJECT_ID \$ENV_NAME (defaults to: main)" >&2
        echo "" >&2
        echo "For example: " >&2
        echo "  bash show_container_distribution.sh szr3gqubqrd2y master" >&2
        exit 1
    fi
else
    PROJECT_ID="$1"
fi


ENV="${2:-main}"
sum_cpu=0
sum_mem=0
skipped_services=()


echo "PROJECT_ID = $PROJECT_ID"
echo "ENV = $ENV"
echo "CMD = $CMD"

$CMD auth:info >/dev/null 2>&1 || {
    echo "Not logged in, asking user to login"
    $CMD login
}

$CMD e:info -e "$ENV" -p "$PROJECT_ID" >/dev/null 2>&1 || {
    echo "ERROR: Selected environment '$ENV' does not exist, please enter the environment name as second parameter."
    echo "$CMD e:info -e $ENV -p $PROJECT_ID"
    $CMD e:list -p "$PROJECT_ID" --no-inactive
    exit 1
}

# Detect plan type (flex vs fixed)
PLAN_TYPE="unknown"
container_profiles=$($CMD project:info subscription.resources.container_profiles -p "$PROJECT_ID" 2>/dev/null | tr -d '[:space:]')
if [ "$container_profiles" = "true" ]; then
    PLAN_TYPE="flex"
elif [ "$container_profiles" = "false" ]; then
    PLAN_TYPE="fixed"
fi
echo "Plan type = $PLAN_TYPE"

# Discover all services: apps + services + workers
services=()

while IFS= read -r name; do
    [ -n "$name" ] && services+=("$name")
done < <($CMD app:list -p "$PROJECT_ID" -e "$ENV" --format csv --no-header --columns=name 2>/dev/null)

while IFS= read -r name; do
    [ -n "$name" ] && services+=("$name")
done < <($CMD service:list -p "$PROJECT_ID" -e "$ENV" --format csv --no-header --columns=name 2>/dev/null)

while IFS= read -r name; do
    [ -n "$name" ] && services+=("$name")
done < <($CMD worker:list -p "$PROJECT_ID" -e "$ENV" --format csv --no-header --columns=name 2>/dev/null)

if [ ${#services[@]} -eq 0 ]; then
    echo "ERROR: No apps, services, or workers found for project $PROJECT_ID on environment $ENV." >&2
    exit 1
fi

echo ""
printf "\e[4;38;2;96;70;255m%-35s %10s %10s %10s %10s %10s\e[0m\n" \
  "Service" "CPU" "Mem(MB)" "CPU (%)" "Mem (%)" "Disk (%)"

echo ""
for service in "${services[@]}"; do
    # Get CPU limit and usage
    cpu=$($CMD cpu --columns limit,percent --service="$service" -1 --format csv --no-header -p "$PROJECT_ID" -e "$ENV" 2>/dev/null | tr -d '\n')
    if [ -z "$cpu" ]; then
        skipped_services+=("$service")
        continue
    fi
    cpu_limit=$(echo "$cpu" | cut -d, -f1)
    cpu_usage=$(echo "$cpu" | cut -d, -f2)

    # Get memory limit and usage
    mem=$($CMD mem --columns limit,percent --service="$service" -1 --format csv --no-header --bytes -p "$PROJECT_ID" -e "$ENV" 2>/dev/null | tr -d '\n')
    mem_limit=$(echo "$mem" | cut -d, -f1)
    mem_usage=$(echo "$mem" | cut -d, -f2)
    mem_limit=$((mem_limit / 1024 / 1024))

    # Get disk usage
    disk_percent=$($CMD disk --columns percent --service="$service" -1 --format csv --no-header --bytes -p "$PROJECT_ID" -e "$ENV" 2>/dev/null | tr -d '\n')

    sum_cpu=$(awk "BEGIN{print $cpu_limit + $sum_cpu}")
    sum_mem=$((mem_limit + sum_mem))

    # Make it red if above 90%
    cpu_color=$([ "${cpu_usage:-0}" -ge 90 ] 2>/dev/null && echo -e "\e[38;2;255;0;0m")
    mem_color=$([ "${mem_usage:-0}" -ge 90 ] 2>/dev/null && echo -e "\e[38;2;255;0;0m")
    disk_color=$([ "${disk_percent:-0}" -ge 90 ] 2>/dev/null && echo -e "\e[38;2;255;0;0m")

    printf "\e[38;2;221;249;51m%-35s\e[0m %10s %10s ${cpu_color}%10s\e[0m ${mem_color}%10s\e[0m ${disk_color}%10s\e[0m\n" \
      "$service" "$cpu_limit" "$mem_limit" "$cpu_usage" "$mem_usage" "$disk_percent"
done
echo " "

# Total row (same color as header, #6046ff)
printf "\e[38;2;96;70;255m%-35s %10.2f %10s %10s %10s %10s\e[0m\n" \
  "Total" "$sum_cpu" "$sum_mem" "" "" ""

echo " "
echo "Plan:"
$CMD project:info subscription -p "$PROJECT_ID" | grep -e 'plan:' -e production | sed -e 's/medium/max_cpu: 2.09, max_memory: 3072/g'

if [ ${#skipped_services[@]} -gt 0 ]; then
    echo ""
    echo "Skipped services (in metadata but not found in environment):"
    for s in "${skipped_services[@]}"; do
        echo "  - $s"
    done
fi

