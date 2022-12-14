#! /usr/bin/env bash
set -Eeuo pipefail

declare -x SCRIPT_COOK_CHECK_LOADED=true

if [[ "${SCRIPT_COOK_COMMON_LOADED:-}" != "true" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
if [[ "${SCRIPT_COOK_IO_LOADED:-}" != "true" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/io.sh"
fi

check::declaration() (
    local -rn declare_inputs_ref="$1"
    local -a error_vars
    local -A rows cols

    common::get_keys_matrix declare_inputs_ref rows cols

    for var in "${!rows[@]}"; do
        if [[ -z "${declare_inputs_ref[$var,param]:+set}" ]]; then
            io::print_error "[$var,param] missing. Please provide a (long) argument by adding [$var,param] to your inputs."
            error_vars+=( "$var" )
        fi
    done
    if [[ -n "${error_vars:+set}" ]] && ((  "${#error_vars[@]}" > 0 )); then
        io::print_error "Found ${#error_vars[@]} errors: ${error_vars[@]}"
        io::print_input_matrix declare_inputs_ref error_vars
        exit 1
    fi
)

check::param() (
    local -rn param_inputs="$1"
    local -rn param_args="$2"
    local var="$3"

    io::print_debug "check if any of (\
${param_inputs[$var,short]:+" ${param_inputs[$var,short]}, "}\
${param_inputs[$var,param]}\
) are contained in: ${param_args[*]}"

    if [[ "${param_args[*]}" =~ ${param_inputs[$var,short]:-} ]] \
        || [[ "${param_args[*]}" =~ ${param_inputs[$var,param]} ]]
    then
        return 0
    fi

    return 1
)

check::param_with_env() (
    local -rn with_env_inputs="$1"
    local -rn with_env_args="$2"
    local var="$3"

    io::print_debug "${with_env_inputs[$var,desc]} is required, checking if provided."

    if [[ -n "${with_env_inputs[$var,value]:+set}" ]] && [[ -n "${with_env_inputs[$var,value]}" ]]; then
        # value is required and provided as environment variable
        io::print_debug "${with_env_inputs[$var,desc]} provided via environment variable."
        return 0
    fi

    if ( check::param with_env_inputs with_env_args "$var" ); then
        # parameter is provided
        io::print_debug "$var provided via parameter."
        return 0
    else
        if [[ -z "${with_env_inputs[$var,value]:+set}" ]]; then
            # value can only be provided as parameter (value not defined), but the parameter is not provided
            io::print_error "${with_env_inputs[$var,desc]} parameter required but not provided."
        else
            # value can be provided as environment variable or parameter (value is defined but empty), but the parameter is not provided in either way
            io::print_error "${with_env_inputs[$var,desc]} environment variable or parameter required but not provided."
        fi
    fi
    return 1
)

check::requirements() {
    local -n req_inputs="$1"
    local -n req_args="$2"

    check::declaration req_inputs || return 1

    io::print_debug "checking requirements"

    local -A rows cols

    common::get_keys_matrix req_inputs rows cols

    # Iterate all variables (rows of the input matrix) and check if the required parameters are set
    # No sanity or value check here, we only check if all parameters are provided
    for var in "${!rows[@]}"; do
        if [[ "${req_inputs[$var,required]:-false}" != "true" ]]; then 
            io::print_debug "${req_inputs[$var,desc]:-} not required, skipping"
            continue
        fi
        check::param_with_env req_inputs req_args "$var" || return 1
    done

    io::print_debug_success "All required parameters are provided. Continuing with sanity check."

    # Iterate all user provided arguments one by one and search for the corresponding input.
    # While checking, we test if:
    # 1. A required parameter is present
    # 2. The parameter is followed by n values
    #   2.1 Values are arguments that are no parameter for the script itself
    #   2.2 If there is a value that equals a parameter, we have to check
    #       2.2.1 whether the parameter is already given or
    #       2.2.2 the parameter is present in a later part of the parameter array
    #   2.3 If the parameter is of type flag (boolean), we don't have to check for further value arguments.
    # 3. If the parameter is not required, we still have to check its sanity by precessing all steps from 2.

    local total_args_length="${#req_args[@]}"
    io::print_debug "Total of $total_args_length arguments"
    local i=0
    while (( i < total_args_length )); do # Iterate all user provided args
        local user_argument="${req_args[$i]}"
        io::print_debug "checking user_argument[$i] = $user_argument"

        # Get current variable for parameter
        local var
        var="$(common::get_variable_from_param req_inputs "$user_argument")"

        # Current argument is not found in req_inputs, continue search for parameters
        if [[ -z "$var" ]]; then
            io::print_debug "  |$user_argument is not a recognized input, continuing."
            ((i++))
            continue
        fi

        io::print_debug "  |Starting req_inputs loop with var = $var, ${req_inputs[$var,param]:-}"

        # If the variable is has a type set and the type is a flag (boolean, tpe == flag),
        # we don't have to check the argument and continue
        if [[ -n "${req_inputs[$var,tpe]:+set}" ]] \
            && [[ "${req_inputs[$var,tpe]:-}" == "flag" ]]; then
            req_inputs+=( ["$var",_checked]="true" )
            io::print_debug "  |$user_argument is flag, skipping further checks"
            ((i++))
            continue
        fi

        # Now we check if the parameter got n arguments (arity), these are not a parameter itself,
        # unless the are provided again as a parameter after n arguments
        # Default arity is n=1.
        local user_arg_arity=${req_inputs[$var,arity]:-1}

        # Separate check if the last argument is a parameter but no value is provided
        if (( i+user_arg_arity  >= total_args_length )); then
            io::print_error "Aborting. Not enough values provided for last parameter ${req_inputs[$var,desc]}."
            return 1
        fi

        local j=$((i+1))
        # Search all following arguments for valid values
        while (( j <= i+user_arg_arity )); do
            if [[ -z "${req_args[$j]:+set}" ]]; then
                io::print_error "Aborting. Not enough values provided for parameter ${req_inputs[$var,desc]}."
                return 1
            fi
            local next_user_argument="${req_args[$j]}"
            io::print_debug "    |next_user_argument[$j] = $next_user_argument"

            # Check if the next argument is not a parameter etc
            for next_var in "${!rows[@]}"; do # all variables from req_inputs
                local next_argument_input="${req_inputs[$next_var,param]}"
                local next_argument_input_short="${req_inputs[$next_var,short]:-}"

                # If the next argument does not equal a parameter, we are save to continue
                if [[ "$next_user_argument" != "$next_argument_input" ]] \
                    && [[ "$next_user_argument" != "$next_argument_input_short" ]]; then
                    io::print_debug "      |$next_user_argument != parameter $next_argument_input and $next_argument_input_short, skipping further checks"
                    continue
                fi

                # If the argument equals a parameter, but that parameter is alreay checked correctly,
                # e.g. it was provided before and checked, we can continue
                if [[ "${req_inputs[$next_var,_checked]:-}" == "true" ]]; then
                    io::print_debug "      |[$j]$next_var is checked already, therefore this can be a valid value"
                    continue
                fi

                # Now, only if the parameter is provided again in the arguments, it can still be a valid
                # argument list and hence a valid command.
                local -i k=$((i+user_arg_arity+1))
                while (( k < total_args_length )); do # args provided by user
                    if [[ "$(common::get_variable_from_param req_inputs "$next_user_argument")" == "$(common::get_variable_from_param req_inputs "${req_args[$k]}")" ]]; then
                        io::print_debug "        |[$j]$next_user_argument is provided again later in the args[$k]"
                        continue 2
                    fi
                    io::print_debug "Lookahead argument is not the parameter $next_user_argument != ${req_args[$k]}"
                    ((k++))
                done

                io::print_error "Aborting. Value of $user_argument is $next_user_argument, which is a parameter, too. However, we couldn't find another $next_user_argument, so it seems like not enough argument are provided. The parameter $user_argument needs $user_arg_arity parameter(s)."
                return 1

            done

            ((j++))
            io::print_debug "    |next value"

        done

        io::print_debug_success "successfully checked $var($user_argument)"
        req_inputs+=( ["$var",_checked]="true" )
        io::print_debug "|next parameter"
        ((i=i+user_arg_arity+1))
    done

    return 0
}

