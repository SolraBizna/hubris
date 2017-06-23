print_memory_usage("beginning")

do_eat_pass()
print_memory_usage("eat")
maybe_error_exit()

do_memorymap_pass()
print_memory_usage("memorymap")
maybe_error_exit()

do_connect_pass()
print_memory_usage("connect")
maybe_error_exit()

do_assign_pass()
print_memory_usage("assign")
maybe_error_exit()

do_generate_pass()
print_memory_usage("generate")
maybe_error_exit()

do_assemble_pass()
print_memory_usage("assemble")
maybe_error_exit()
