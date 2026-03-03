output "ssh_command_rocky" {
  description = "SSH command to connect to the Rocky Linux VM"
  value       = "gcloud compute ssh --project ${var.project_id} --zone ${var.zone} ${var.rocky_vm_name}"
}

output "ssh_command_ubuntu" {
  description = "SSH command to connect to the Ubuntu VM"
  value       = "gcloud compute ssh --project ${var.project_id} --zone ${var.zone} ${var.ubuntu_vm_name}"
}
