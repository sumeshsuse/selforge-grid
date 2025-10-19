data "aws_region" "current" {}

module "network" {
  source      = "./modules/network"
  name_prefix = var.name_prefix
  grid_cidrs  = var.grid_cidrs
}

module "alb" {
  source       = "./modules/alb"
  name_prefix  = var.name_prefix
  vpc_id       = module.network.vpc_id
  subnet_ids   = module.network.subnet_ids
  alb_sg_id    = module.network.alb_sg_id
}

module "ecs_selenium" {
  source        = "./modules/ecs_selenium"
  name_prefix   = var.name_prefix
  cpu           = var.cpu
  memory        = var.memory
  desired_count = var.desired_count

  region       = data.aws_region.current.name
  subnet_ids   = module.network.subnet_ids
  svc_sg_id    = module.network.svc_sg_id

  grid_tg_arn  = module.alb.grid_tg_arn
  novnc_tg_arn = module.alb.novnc_tg_arn
}
