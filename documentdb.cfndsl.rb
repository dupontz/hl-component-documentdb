CloudFormation do

  # Condition('SnapshotSet', FnNot(FnEquals(Ref('Snapshot'), '')))
  # Condition('SnapshotNotSet', FnEquals(Ref('Snapshot'), ''))

  tags = []
  extra_tags.each { |key,value| tags << { Key: FnSub(key), Value: FnSub(value) } } if defined? extra_tags

  Resource("SSMSecureParameter") {
    # Condition 'SnapshotNotSet'
    Type "Custom::SSMSecureParameter"
    Property('ServiceToken', FnGetAtt('SSMSecureParameterCR', 'Arn'))
    Property('Length', master_credentials['password_length']) if master_credentials.has_key?('password_length')
    Property('Path', FnSub("#{master_credentials['ssm_path']}/password"))
    Property('Description', FnSub("${EnvironmentName} DocumentDB Password"))
    Property('Tags',[
      { Key: 'Name', Value: FnSub("${EnvironmentName}-documentdb-password")},
      { Key: 'Environment', Value: FnSub("${EnvironmentName}")},
      { Key: 'EnvironmentType', Value: FnSub("${EnvironmentType}")}
    ])
  }

  SSM_Parameter("ParameterSecretKey") {
    # Condition 'SnapshotNotSet'
    Name FnSub("#{master_credentials['ssm_path']}/username")
    Type 'String'
    Value "#{master_credentials['username']}"
  }

  EC2_SecurityGroup(:DocDBSecurityGroup) {
    VpcId Ref('VPCId')
    GroupDescription "DocumentDB communication"
    Tags([{ Key: 'Name', Value: FnSub("${EnvironmentName}-#{component_name}")}] + tags)
    Metadata({
      cfn_nag: {
        rules_to_suppress: [
          { id: 'F1000', reason: 'adding rules using cfn resources' }
        ]
      }
    })
  }

  DocDB_DBSubnetGroup(:DocDBSubnetGroup) {
    DBSubnetGroupDescription FnSub("${EnvironmentName} #{component_name}")
    SubnetIds FnSplit(',', Ref('SubnetIds'))
    Tags([
      { Key: 'Name', Value: FnSub("${EnvironmentName}-#{component_name}-subnet-group") }
    ])
  }

  DocDB_DBCluster(:DocDBCluster) {
    DBClusterParameterGroupName Ref(:DocDBClusterParameterGroup) if defined?(cluster_parameters)
    DBSubnetGroupName Ref(:DocDBSubnetGroup)
    KmsKeyId Ref('KmsKeyId') if defined? kms
    StorageEncrypted storage_encrypted if defined? storage_encrypted
    VpcSecurityGroupIds [Ref(:DocDBSecurityGroup)]
    # If snapshot value is set in the parameter
    # SnapshotIdentifier FnIf('SnapshotSet', Ref('Snapshot'), Ref('AWS::NoValue'))
    SnapshotIdentifier Ref('Snapshot')
    # else use the username and password
    MasterUsername master_credentials['username']
    MasterUserPassword FnGetAtt("SSMSecureParameter","Password")
    # MasterUsername FnIf('SnapshotNotSet', "#{master_credentials['username']}", Ref('AWS::NoValue'))
    # MasterUserPassword FnIf('SnapshotNotSet', FnGetAtt("SSMSecureParameter","Password"), Ref('AWS::NoValue'))
    # end
    Tags([{ Key: 'Name', Value: FnSub("${EnvironmentName}-#{component_name}-cluster")}] + tags)
  }

  family = external_parameters.fetch(:family,'docdb3.6')

  if defined?(cluster_parameters)
    DocDB_DBClusterParameterGroup(:DocDBClusterParameterGroup) {
      Description "Parameter group for the #{component_name} cluster"
      Family family
      Name FnSub("${EnvironmentName}-#{component_name}-cluster-parameter-group")
      Parameters cluster_parameters
      Tags [{ Key: 'Name', Value: FnSub("${EnvironmentName}-#{component_name}-cluster-parameter-group")}] + tags
    }
  end
  
  DocDB_DBInstance(:DocDBInstanceA) {
    DBClusterIdentifier Ref(:DocDBCluster)
    DBInstanceClass Ref('InstanceType')
    Tags([{ Key: 'Name', Value: FnSub("${EnvironmentName}-#{component_name}-instance-A")}] + tags)
  }


  replicas = external_parameters.fetch(:replicas, 1)
  replicas.times do | replica|
    DocDB_DBInstance(:DocDBInstanceReplica) {
      DBClusterIdentifier Ref(:DocDBCluster)
      DBInstanceClass Ref('InstanceType')
      Tags([{ Key: 'Name', Value: FnSub("${EnvironmentName}-#{component_name}-instance")}] + tags)
    }
  end

  Route53_RecordSet(:DBHostRecord) {
    HostedZoneName FnJoin('', [ Ref('EnvironmentName'), '.', Ref('DnsDomain'), '.'])
    Name FnJoin('', [ hostname, '.', Ref('EnvironmentName'), '.', Ref('DnsDomain'), '.' ])
    Type 'CNAME'
    TTL '60'
    ResourceRecords [ FnGetAtt('DocDBCluster','Endpoint') ]
  }

  Output(:DocDBSecurityGroup) {
    Value Ref(:DocDBSecurityGroup)
  }

end
