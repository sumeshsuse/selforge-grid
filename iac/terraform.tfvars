name_prefix   = "selenium-fargate"
desired_count = 1
cpu           = 1024
memory        = 2048
grid_cidrs    = ["0.0.0.0/0"]  # tighten this later for prod