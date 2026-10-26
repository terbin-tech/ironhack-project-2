variable "alarm_email" {
  description = "Address the state-bucket alarm emails; set it in the git-ignored terraform.tfvars. Without it the alarm has no subscriber."
  type        = string
  default     = null
}
