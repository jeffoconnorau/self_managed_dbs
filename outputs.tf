output "ssh_command_mysql" {
  description = "SSH command to connect to the MySQL VM"
  value       = var.enable_mysql_vm ? "gcloud compute ssh --project ${var.project_id} --zone ${var.zone} ${local.mysql_vm_name}" : "MySQL VM is disabled"
}

output "ssh_command_rocky" {
  description = "Legacy alias for MySQL VM SSH command"
  value       = var.enable_mysql_vm ? "gcloud compute ssh --project ${var.project_id} --zone ${var.zone} ${local.mysql_vm_name}" : "MySQL VM is disabled"
}

output "ssh_command_postgres" {
  description = "SSH command to connect to the PostgreSQL VM"
  value       = var.enable_postgres_vm ? "gcloud compute ssh --project ${var.project_id} --zone ${var.zone} ${local.postgres_vm_name}" : "PostgreSQL VM is disabled"
}

output "ssh_command_ubuntu" {
  description = "Legacy alias for PostgreSQL VM SSH command"
  value       = var.enable_postgres_vm ? "gcloud compute ssh --project ${var.project_id} --zone ${var.zone} ${local.postgres_vm_name}" : "PostgreSQL VM is disabled"
}

output "ssh_command_db2" {
  description = "SSH command to connect to the IBM Db2 VM"
  value       = var.enable_db2_vm ? "gcloud compute ssh --project ${var.project_id} --zone ${var.zone} ${var.db2_vm_name}" : "Db2 VM is disabled"
}


