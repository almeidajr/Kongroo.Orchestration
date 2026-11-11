from cfnlint.rules import CloudFormationLintRule, RuleMatch


class NoNodeRoleAccessEntry(CloudFormationLintRule):
    id = "E9001"
    shortdesc = "No EKS access entry for the node role"
    description = (
        "LabRole is the node role. An access entry for it displaces the EC2_LINUX entry the node group "
        "creates, so nodes join as a plain user and their kubelet certificates are never approved."
    )
    tags = ["eks", "labrole"]

    def match(self, cfn):
        # Matches the principal's text, so a literal, !Sub or !Join naming LabRole is caught alike.
        return [
            RuleMatch(
                ["Resources", name, "Properties", "PrincipalArn"],
                f"{name} is an access entry for the node role (LabRole); the node group creates its own EC2_LINUX entry",
            )
            for name, entry in cfn.get_resources(["AWS::EKS::AccessEntry"]).items()
            if "LabRole" in str(entry.get("Properties", {}).get("PrincipalArn"))
        ]
