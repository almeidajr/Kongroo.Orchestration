from cfnlint.rules import CloudFormationLintRule, RuleMatch


class NoNodeRoleAccessEntry(CloudFormationLintRule):
    id = "E9001"
    shortdesc = "No EKS access entry for the node role"
    description = (
        "LabRole is the node role. An access entry for it displaces the EC2_LINUX entry the node group "
        "creates, so nodes join as a plain user and their kubelet certificates are never approved (ADR 0001)."
    )
    source_url = ""
    tags = ["eks", "labrole"]

    def match(self, cfn):
        node_roles = [
            node_group.get("Properties", {}).get("NodeRole")
            for node_group in cfn.get_resources(["AWS::EKS::Nodegroup"]).values()
        ]
        return [
            RuleMatch(
                ["Resources", name, "Properties", "PrincipalArn"],
                f"{name} is an access entry for the node role (LabRole); the node group creates its own EC2_LINUX entry",
            )
            for name, entry in cfn.get_resources(["AWS::EKS::AccessEntry"]).items()
            if (principal := entry.get("Properties", {}).get("PrincipalArn")) in node_roles
            or "LabRole" in str(principal)
        ]
