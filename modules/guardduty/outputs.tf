output "detector_id" {
  value = aws_guardduty_detector.this.id
}

output "features" {
  description = "Protection plan => status, as configured here."
  value       = { for name, feature in aws_guardduty_detector_feature.this : name => feature.status }
}

output "additional" {
  description = "Protection plan => its add-ons and their status, as configured here."
  value = {
    for name, feature in aws_guardduty_detector_feature.this :
    name => { for addition in feature.additional_configuration : addition.name => addition.status }
  }
}
