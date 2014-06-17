#!/usr/bin/ruby
#============================================
# Script: check_ec2_meta_moniotor
# Author: Magnus Luebeck, magnus.luebeck@kmggroup.ch
# Date:   2014-05-19
#
# Description: This script will list instances in AWS and their 
#              current monitoring status
#
# Copyright 2014 KMG Group GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
#     http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.
#
# Note: A lot of this plugin has been inspired by check_cloudwatch_status.rb from SecludIT, which
#       can be downloaded from:
#       http://exchange.nagios.org/directory/Plugins/Operating-Systems/*-Virtual-Environments/Others/Check_AWS_CloudWatch_metrics/details
#============================================

%w[ rubygems getoptlong yaml aws-sdk pp ].each { |f| require f }
$stdout.sync = true

#============================================
# Predefined variables 
#============================================
AWS_NAMESPACE_EC2             = "AWS/EC2"
AWS_NAMESPACE_RDS             = "AWS/RDS"
AWS_NAMESPACE_ELB             = "AWS/ELB"
AWS_NAMESPACE_BILLING         = "AWS/Billing"
AWS_NAMESPACE_DATATRANSFER    = "AWS/Data"
AWS_NAMESPACE_S3              = "AWS/S3"

AWS_METRIC_ELB = "HealthyHostCount" #Default metric


#--- Reference for API Class: AWS::CloudWatch::Metric
#---  http://docs.aws.amazon.com/AWSRubySDK/latest/AWS/CloudWatch/Metric.html#statistics-instance_method
#--- Reference for API Class AWS::CloudWatch::Client
#--- http://docs.aws.amazon.com/AWSRubySDK/latest/AWS/CloudWatch/Client.html

#--- Reference for AWS Cloudwatch Namespaces, Dimensions, and Metrics
#---  http://docs.aws.amazon.com/AmazonCloudWatch/latest/DeveloperGuide/CW_Support_For_AWS.html


#--- Available metrics for ELB -> http://docs.aws.amazon.com/AmazonCloudWatch/latest/DeveloperGuide/elb-metricscollected.html
#---     BackendConnectionErrors  -> Use --statistics
#---     HealthyHostCount
#---     HTTPCode_Backend_2XX
#---     HTTPCode_Backend_3XX
#---     HTTPCode_Backend_4XX
#---     HTTPCode_ELB_5XX
#---     Latency
#---     RequestCount
#---     UnHealthyHostCount

#--- Default metrics for EC2 -> http://docs.aws.amazon.com/AmazonCloudWatch/latest/DeveloperGuide/ec2-metricscollected.html
#---     StatusCheckFailed_Instance
#---     StatusCheckFailed
#---     DiskWriteBytes
#---     NetworkIn
#---     NetworkOut
#---     CPUUtilization
#---     DiskWriteOps
#---     DiskReadOps
#---     DiskReadBytes
#---     StatusCheckFailed_System


AWS_STATISTICS  = ["Average","Minimum","Maximum", "Sum"]
AWS_STATISTICS_WINDOW = 300                    # in seconds
AWS_STATISTICS_PERIOD = AWS_STATISTICS_WINDOW  # in seconds (since we are not plotting anything, we only need one value)

NAGIOS_CODE_OK        = {:value => 0, :msg => "OK" }
NAGIOS_CODE_WARNING   = {:value => 1, :msg => "WARNING" }
NAGIOS_CODE_CRITICAL  = {:value => 2, :msg => "CRITICAL" }
NAGIOS_CODE_UNKNOWN   = {:value => 3, :msg => "UNKNOWN" }


OUTPUT_ZERO           = {:average => 0, :minimum => 0, :maximum => 0, :sum => 0, :timestamp => "", :unit => 0}

#--- the config file will be looked for in the same directory as this script
#--- Use -C to point to another directory
configDir   = File.expand_path(File.dirname(__FILE__) )
configFile  = File.expand_path(configDir + '/config.yml')

regionOverride    = nil
accessKeyOverride = nil
secretKeyOverride = nil
noMonitoringTag   = nil
                     
instance_id       = nil

#namespace         = AWS_NAMESPACE_ELB
namespace         = ""
metric            = AWS_METRIC_ELB
statistics        = AWS_STATISTICS
statisticsWindow  = AWS_STATISTICS_WINDOW
statisticsPeriod  = AWS_STATISTICS_PERIOD
optPeriod         = nil
optWindow         = nil
optBilling        = nil

thresholdCritical = nil
thresholdWarning  = nil
optListMetrics    = false
optListInstances  = false
#--- optNoRunCheck -> false => check if the instance is running, before fetching metrics
optNoRunCheck     = true

retCode = {:value => 0}

$debug    = false
$verbose  = false

#============================================
# Parameter parsing
#============================================

opts = GetoptLong.new
opts.set_options(
  [ "--help-short", "-h", GetoptLong::NO_ARGUMENT],
  [ "--help", GetoptLong::NO_ARGUMENT],
  [ "--billing", GetoptLong::NO_ARGUMENT],
  [ "--region", "-r", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--access_key", "-a", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--instance", "-i", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--secret_key", "-s", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--list-metrics", "-l", GetoptLong::NO_ARGUMENT],
  [ "--list-instances", GetoptLong::NO_ARGUMENT],
  [ "--no-run-check", GetoptLong::NO_ARGUMENT],
  [ "--namespace", "-N", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--ec2", GetoptLong::NO_ARGUMENT],
  [ "--elb", GetoptLong::NO_ARGUMENT],
  [ "--rds", GetoptLong::NO_ARGUMENT],
  [ "--metric", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--window", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--period", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--critical", "-c", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--warning", "-w", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--verbose", "-v", GetoptLong::NO_ARGUMENT],
  [ "--debug", GetoptLong::NO_ARGUMENT],
  [ "--statistics", GetoptLong::OPTIONAL_ARGUMENT],
  [ "--config", "-C", GetoptLong::OPTIONAL_ARGUMENT]
)


#============================================
# Functions
#============================================
#-------------------------------------------------------------------
# usageShort
#-------------------------------------------------------------------
def usageShort

  puts <<EOT
  
  Usage: #{$0} --instance=<instance id|name> --metric=<metric>

  Options:  [-A <access key>] [-S <secret key>][-h] [-C <pathToConfig>] [-r <region>] [--list-metrics] [--namespace=<AWS namespace>]
            [--window=<window in seconds>] [--period=<period in seconds>] [--statistics="Statistic1,Statistic2,..."] [--verbose | -v] [--debug]
            [-w <range> | --warning=<range>] [-c <range> | --critical=<range>]

  Simplify your use of this command by keeping your credentials in config.yml. For full help, use option --help

EOT
end


#-------------------------------------------------------------------
# usage
#-------------------------------------------------------------------
def usage
  puts <<EOT
Usage: #{$0}
  --help, -h:                              This Help
  --config, -C:                            Use config file (default ../etc/config.yml)
  --region=region, -r region:              Connect to region (i.e us-west-1, us-west-2)
  --access_key=ACCESS_KEY, -A ACCESS_KEY:  Use access key
  --secret_key=ACCESS_KEY, -S ACCESS_KEY:      Use secret access key
  --instance, -i:                          Instance id or Load balancer name
  --list-metrics                           List available metrics (should be used together with -i)
  --list-instances                         List EC2 instances
  --metric=<metric>                        Metric to report
  --namespace=<namespace>                  Set the namespace
  --no-run-check                           Do not check if an instance is running before fetching metrics (speeds up the check by ca 2 seconds)
  --ec2
  --elb
  --rds
  --window=<seconds>:                      Time in seconds for the number of seconds back in time to fetch statistics
  --period=<seconds>:                      Time in seconds for the bin-size of the statistics (multiple of 60 seconds, but for practical reasons should be the same as --window)
  --statistics:                            Statistics to gather, default "Average,Minimum,Maximum". Can also include Sum and Count. The first one can be checked against thresholds.
  --verbose,-v:                            Show some more output on stderr on what is going on
  --debug:                                 Show a lot more output on stderr on what is going on
  
  Thresholds:
  
  --warning={@}<threshold>{+}, -w {@}<threshold>{+}
  --critical={@}<threshold>{+}, -c {@}<threshold>{+}

  The threshold can be a single value or a range and can be decimal values. A threshold can be checked to be within a range or outside a range.
  To alert when a value is outside a range, use the prefix "@". The values can be checked with "hard" (default) or "soft" precision (by suffixiing
  the threshold with a "+"). Valid thresholds are:
  
  1, 1.0, 1:+, :1.5, 0:1000, @1:100
  
  "-c 75"    will trigger when the value is equal to or larger than 75
  "-c 75+"   will trigger when the value is larger than 75
  "-c 0:1"   will trigger when the value is equal to or larger than 0 and equal to or less than 1 
  "-c 0:1+"  will trigger when the value is larger than 0 and less than 1
Example:

* The authentication and settings in ../etc/config.yml are used, but region is us-west-2

  #{$0} --region=us-west-2

* Use another config file than default (config.yml)

  #{$0} --config=/path/to/my/config/file.yml
  
Critical and Warning thresholds

The warning and critical thresholds are defined as ranges, where an alert will be triggerd depending of whether the checked value is 
inside the range or outside the range. A single threshold passed to -c or -w will be treated as the range -Infinity to <threshold>, and
an alert will be triggered if the checked value is larger or equal to the threshold.

-c 2   -> critical alert triggered if the value is equal to or larger than 2
-c 2+  -> critical alert triggered if the value is larger than 2
-c :2  -> critical alert triggered if the value is equal to or less than 2
-c :2+  -> critical alert triggered if the value is less than 2

-c :1.99999999 is nearly identical to -c :2+

Contact:

Please report bugs and feature requests to magnus.luebeck@kmggroup.ch

EOT
end

#-------------------------------------------------------------------
# listMetrics
#-------------------------------------------------------------------
def listMetrics(namespace, instance_id)

  $stderr.puts "* Entering: #{thisMethod()}" if $debug

  aws_api = AWS::CloudWatch.new()

  case namespace
    when AWS_NAMESPACE_EC2
      dimensionCriteria="InstanceId"
    when AWS_NAMESPACE_RDS
      dimensionCriteria="DBInstanceIdentifier"
    when AWS_NAMESPACE_ELB
      dimensionCriteria="LoadBalancerName"
    when AWS_NAMESPACE_BILLING
      dimensionCriteria=""
    else
      return 0
  end
  
  if (instance_id.nil?)
    dimensions = []
  else
    dimensions = [{:value => instance_id, :name => dimensionCriteria }]
  end

  metrics = aws_api.client.list_metrics({:namespace=> namespace, :dimensions =>dimensions}).data[:metrics]
  metrics.each do | metric |
   puts "====================== " + metric[:metric_name] + " ================================" if $debug
    pp metric if $debug
    if (!metric[:dimensions][0].nil?)
      puts "#{metric[:dimensions][0][:value]};#{metric[:metric_name]}"
    else
      puts ";#{metric[:metric_name]}"
    end
    
  end
end

#-------------------------------------------------------------------
# listEC2Instances
#-------------------------------------------------------------------
def listEC2Instances(noMonitoringTag)
  $stderr.puts "* Entering: #{thisMethod()}" if $debug

  aws_api = AWS::EC2.new()
  
  response = aws_api.client.describe_instances
  instances = response[:reservation_set]
  
  #--- loop through all instances
  instances.each do |instance|
    curInstance = instance[:instances_set][0]
  
    instanceName     = "" 
    noMonitoring     = "" 
    instanceId       = curInstance[:instance_id]
    privateIpAddress = curInstance[:private_ip_address]
    availabilityZone = curInstance[:placement][:availability_zone]
  
    curInstance[:tag_set].each do | item |
      case item[:key]
        when 'Name'
          instanceName = item[:value]
        when noMonitoringTag
          noMonitoring = item[:value].nil? ? "" : item[:value]
      end
    end
  
    printf "Name: %-20s Id: %-14s privateIp: %-18s State: Zone: %s\n", instanceName, instanceId, privateIpAddress, curInstance[:instance_state][:name], availabilityZone

  end
end

#-------------------------------------------------------------------
# EC2InstanceRunning
#-------------------------------------------------------------------
def EC2InstanceRunning(instanceId)
  $stderr.puts "* Entering: #{thisMethod()}" if $debug 
  $stderr.puts "  - Checking running state of #{instanceId}" if $debug

  aws_api = AWS::EC2.new()
   
  #--- get the instance running state
  response = aws_api.client.describe_instances({:instance_ids => [ instanceId ]})[:reservation_set][0][:instances_set][0][:instance_state][:name]
#  $stderr.puts response if $debug
  $stderr.puts "  - Done checking running state of #{instanceId} (#{response})" if $debug
  if (response == "running")
    return true
  else
    return false
  end
end

#-------------------------------------------------------------------
# getCloudwatchStatistics
#-------------------------------------------------------------------
def getCloudwatchStatistics(namespace, metric, statistics, dimensions, window, period)
  $stderr.puts "* Entering: #{thisMethod()}" if $debug 

  $stderr.puts "  - Namespace: #{namespace} Dimensions: #{dimensions} Metric: #{metric} Window: #{window} Period: #{period}" if $debug

  begin
    aws_api = AWS::CloudWatch.new()
    params = {
      :metric_name => metric,
      :period      => period,
      :start_time  => (Time.now() - window).iso8601,
      :end_time    => Time.now().iso8601,
      :statistics  => statistics, #--- should normally be "Average", unless you want to sum up 
      :namespace   => namespace,
      :dimensions  => dimensions     
    }
    
    metrics = aws_api.client.get_metric_statistics( params  )

    if metrics && metrics[:datapoints] && metrics[:datapoints][0] && metrics[:datapoints][0][:timestamp]
      # Cloudwatch doesn't necessarily sort the values. Ensure that they are.
      metrics[:datapoints].sort!{|a,b| a[:timestamp] <=> b[:timestamp]}
    end
    
  rescue Exception => e
    $stderr.puts "ERROR: Could not get cloudwatch stats: #{metric}"
    $stderr.puts "  - parameters: #{params.inspect}" if $debug
  end
  
  return metrics
  
end

#-------------------------------------------------------------------
# awsGetBilling
#-------------------------------------------------------------------
def awsGetBilling(namespace)
  $stderr.puts "* Entering: #{thisMethod()}" if $debug 

  #--- all billing is reported from us-east-1
  AWS.config(:region=>'us-east-1')
  
  $stderr.puts "  - Billing type: #{namespace.inspect}" if $debug
  case namespace
    when 'all'
      dimensions = [{:name=>"Currency"    , :value=>"USD"}]
    when AWS_NAMESPACE_EC2
      dimensions = [{:name=>"ServiceName" , :value=>"AmazonEC2"}      , {:name=>"Currency", :value=>"USD"}]
    when AWS_NAMESPACE_RDS
      dimensions = [{:name=>"ServiceName" , :value=>"AmazonRDS"}      , {:name=>"Currency", :value=>"USD"}]
    when AWS_NAMESPACE_DATATRANSFER
      dimensions = [{:name=>"ServiceName" , :value=>"AWSDataTransfer"}, {:name=>"Currency", :value=>"USD"}]
    when AWS_NAMESPACE_S3
      dimensions = [{:name=>"ServiceName" , :value=>"AWSDataS3"}      , {:name=>"Currency", :value=>"USD"}]
    else 
      dimensions = [{:name=>"Currency"    , :value=>"USD"}]
  end
  
  $stderr.puts "  - dimensions: #{dimensions.inspect}" if $debug
  
  metrics = getCloudwatchStatistics("AWS/Billing", "EstimatedCharges", ["Maximum"], dimensions, 3600*24, 3600*24)

  $stderr.puts "  - metrics: #{metrics.inspect}" if $debug

  return metrics
end

#-------------------------------------------------------------------
# thisMethod, helper method to print the method name when debugging
#-------------------------------------------------------------------
def thisMethod
  caller[0]=~/`(.*?)'/  # note the first quote is a backtick
  $1
end

#--------------------------------------------------------
# parseThreshold
#--------------------------------------------------------

def parseThreshold(inputArg)

  $stderr.puts "* Entering: #{thisMethod()}" if $debug

  #--- check for range
  $stderr.puts "  - Parsing threshold #{inputArg.inspect}" if $debug
  arg = String.new( inputArg )

  values = {}

  if (inputArg == "")
    return values
  end
  
  softCheck = false
  values[:precision] = "hard"
  
  if (arg =~ /\+/)
    values[:precision] = "soft"
    arg.gsub!( /\+/, '')
  end
  
  if (arg =~ /^-?[0-9]+\.?[0-9]*$/)
    #--- only one value, range from 0 up to this value, check will be inside this range
    values[:type]     = "outside-range"
    values[:floor]    = (-1.0/0) # Infinity
    values[:ceiling]  = arg.to_f()
  elsif (arg =~ /^-?[0-9]+\.?[0-9]*:$/)
    #--- only one value, range from this value up to infinity
    values[:type]     = "inside-range"
    values[:floor]    = arg.gsub!( /:/, '' ).to_f()
    values[:ceiling]  = (+1.0/0.0)	# +Infinity
  elsif (arg =~ /^:-?[0-9]+\.?[0-9]*$/)
    #--- only one value, range from negative infinity up to this value
    arg.gsub!( /~/, '' )
    values[:type]     = "inside-range"
    values[:floor]    = (-1.0/0.0)	# -Infinity
    values[:ceiling]  = arg.gsub!( /:/, '' ).to_f()
  elsif (arg =~ /^-?[0-9]+\.?[0-9]*:-?[0-9]+\.?[0-9]*$/)
    #--- two values, range from first to second value, check will be inside this range
    values_str = arg.split( /:/ )
    values[:type]     = "inside-range"
    values[:floor]    = values_str[0].to_f()
    values[:ceiling]  = values_str[1].to_f()
  elsif (arg =~ /^@-?[0-9]+\.?[0-9]*:-?[0-9]+\.?[0-9]*$/)
    #--- two values, range from first to second value, check will be outside this range
    arg.gsub!( /@/, '' )
    values_str = arg.split( /:/ )
    #values_str.reverse!()
    values[:type]     = "outside-range"
    values[:floor]    = values_str[0].to_f()
    values[:ceiling]    = values_str[1].to_f()
  else
    $stderr.puts "  - Could not parse this value (#{inputArg})" if $debug
    exit 1
  end

  $stderr.puts "  - values: #{values}" if $debug
  
  return values
end

#--------------------------------------------------------
# checkThreshold
#--------------------------------------------------------
def checkThreshold(checkValueStr, threshold)

  $stderr.puts "* Entering: #{thisMethod()}" if $debug

  checkValue = checkValueStr.to_f()
  
  $stderr.puts "  - checkValueStr: #{checkValueStr} checkValue: #{checkValue}" if $debug
  $stderr.puts "  - threshold type: #{threshold[:type]} floor: #{threshold[:floor]} ceiling: #{threshold[:ceiling]}" if $debug
  case threshold[:type]
  when "outside-range"
    $stderr.puts "  - Checking outside-range" if $debug
    case threshold[:precision]
    when "hard"
        #--- =c 2 -> a value of 2 or above will trigger
        if (checkValue <= threshold[:floor] || checkValue >= threshold[:ceiling] )
          $stderr.puts "  - Is outside the range #{threshold[:floor]} and #{threshold[:ceiling]}" if $debug
          return false
        end
    when "soft"
      #--- -c 2 -> a value larger than 2 will trigger
      if (checkValue < threshold[:floor] || checkValue > threshold[:ceiling] )
        $stderr.puts "  - Is outside the range #{threshold[:floor]} and #{threshold[:ceiling]}" if $debug
        return false
      end
    end      
  when "inside-range"
    puts "Checking inside-range #{threshold[:precision]}" if $debug
    case threshold[:precision]
    when "hard"
      if (checkValue >= threshold[:floor] && checkValue <= threshold[:ceiling] )
        return false
      end
    when "soft"
      if (checkValue > threshold[:floor] && checkValue < threshold[:ceiling] )
        return false
      end
    end
  end
  
  return true
end

#--------------------------------------------------------
# checkThresholds
#--------------------------------------------------------
def checkThresholds(checkValueStr, thresholdWarning, thresholdCritical)
  $stderr.puts "* Entering: #{thisMethod()}" if $debug

  if (!thresholdCritical.nil? && !checkThreshold(checkValueStr, thresholdCritical))
    return NAGIOS_CODE_CRITICAL
  elsif (!thresholdWarning.nil? && !checkThreshold(checkValueStr,thresholdWarning))
    return NAGIOS_CODE_WARNING
  else
    return NAGIOS_CODE_OK
  end
end
  
  
#--------------------------------------------------------
# printPerfdata
#--------------------------------------------------------
def printPerfdata(statistics, output)
  
  print "|"
  
  loopCount=0
  statistics.each do |statistic|
    if (loopCount > 0)
      print " "
    end
  
    case statistic
    when "Average"
        printf "#{statistic}=%.6f", output[:average]
    when "Minimum"
        printf "#{statistic}=%.6f", output[:minimum]
    when "Maximum"
        printf "#{statistic}=%.6f", output[:maximum]
    when "Sum"
        printf "#{statistic}=%.6f", output[:sum]
    when "Count"
        printf "#{statistic}=%.6f", output[:count]
    end
  
    loopCount += 1
  end  
  puts #--- end of line
  
end

#--------------------------------------------------------
# getCheckValue
#--------------------------------------------------------
def getCheckValue(statistics, output)
  #--- get the value to check
  reportValue=0
  case statistics[0]
  when 'Average'
    reportValue = output[:average]
  when 'Minimum'
    reportValue = output[:minimum]
  when 'Maximum'
    reportValue = output[:maximum]
  when 'Count'
    reportValue = output[:count]
  when 'Sum'
    reportValue = output[:sum]
  end

  return reportValue
end
#============================================
#============================================
#                   MAIN 
#============================================
#============================================

#============================================
# Parse options
#============================================

#--- go through options
opts.each { |opt,arg|
  case opt
    when '--help'
      usage
      exit 0
    when '--help-short'
      usageShort
      exit 0
    when '--config'
      configFile        = arg 
    when '--region'
      regionOverride    = arg
    when '--access_key'
      accessKeyOverride = arg
    when '--secret_key'
      secretKeyOverride = arg
    when '--instance'
      instance_id       = arg
    when '--namespace'
      namespace         = arg
    when '--ec2'
      namespace         = AWS_NAMESPACE_EC2
    when '--elb'
      namespace         = AWS_NAMESPACE_ELB
    when '--rds'
      namespace         = AWS_NAMESPACE_RDS
    when '--list-instances'
      optListInstances  = true
    when '--list-metrics'
      optListMetrics    = true
    when '--window'
      statisticsWindow  = arg.to_i
      optWindow = statisticsWindow
    when '--period'
      statisticsPeriod  = arg.to_i
      optPeriod         = statisticsPeriod
    when '--metric'
      metric            = arg
    when '--verbose'
      $verbose          = true
    when '--debug'
      $debug            = true
    when '--critical'
      thresholdCritical = parseThreshold(arg)
    when '--warning'
      thresholdWarning  = parseThreshold(arg)
    when '--statistics'
      statistics        = arg.split(/,/)
    when '--no-run-check'
      optNoRunCheck = true
    when '--billing'
      optBilling = true
  end
}


#--- minor quirks

#--- if optPeriod is not set, the period should be equal to the window. It can be useful to use --window=3600 --period=60 --debug
#--- to see data points over a period of one hour.
#--- Some metrics are not updated on a minute basis! To get the latest value, you have to ask for, say, a window of 600 seconds, but
#--- set the bucket size to 60 or 120 seconds.

statisticsPeriod = statisticsWindow if (optPeriod.nil? && !optWindow.nil?)
$stderr.puts "* Setting up statistics window = #{statisticsWindow} and statistics period = #{statisticsPeriod}" if $debug

$verbose = true if $debug

#============================================
# Config file (yml)
#============================================

if File.exist?(configFile)
  $stderr.puts "* Reading config file #{configFile}" if $debug
  config = YAML.load(File.read(configFile))
else
  $stderr.puts "WARNING: #{configFile} does not exist" if $verbose
end

#============================================
# Setup dimensions
#============================================

if namespace.eql?(AWS_NAMESPACE_EC2)
  dimensions = [{:name => "InstanceId", :value => instance_id} ]
elsif namespace.eql?(AWS_NAMESPACE_RDS)
  dimensions = [{:name => "DBInstanceIdentifier", :value => instance_id}]
elsif namespace.eql?(AWS_NAMESPACE_ELB)
  dimensions = [{:name => "LoadBalancerName", :value => instance_id}]
end

$stderr.puts "* Setting up dimensions to #{dimensions}" if $debug

#============================================
# Setup connection to AWS
#============================================

#pp config["aws"] if $debug

$stderr.puts "* AWS Config" if $debug

AWS.config(config["aws"]) unless config.nil?
#--- if --region was used
AWS.config(:region => regionOverride) unless regionOverride.to_s.empty?
#--- if --access_key was used
AWS.config(:access_key_id => accessKeyOverride) unless accessKeyOverride.to_s.empty?
#--- if --secret was used
AWS.config(:secret_access_key => secretKeyOverride) unless secretKeyOverride.to_s.empty?


#--- list instances
if (optListInstances)
  listEC2Instances("")
  exit 0
end
#--- list metrics
if (optListMetrics)
  listMetrics(namespace, instance_id)
  exit 0
end

if (optBilling)
  metrics = awsGetBilling(namespace)

  if ( metrics && metrics[:datapoints].count > 0)
    lastMetric = metrics[:datapoints][-1]
    $stderr.puts "  - lastMetric: #{lastMetric.inspect}" if $debug
    retCode=checkThresholds(lastMetric[:maximum], thresholdWarning, thresholdCritical)
    printf "#{retCode[:msg]} - Namespace: #{namespace} Metric: Cost, Last Value: $%.2f Unit: #{lastMetric[:unit]} (#{lastMetric[:timestamp]})\n", lastMetric[:maximum]
    printPerfdata(["Maximum"], lastMetric)

  else
    puts "Billing metrics not enabled for #{namespace}."
  end

  exit retCode[:value]
end

#--- EC2-instances
if ( (optNoRunCheck || EC2InstanceRunning(instance_id)) || namespace != AWS_NAMESPACE_EC2 )

  metrics = getCloudwatchStatistics(namespace, metric, statistics, dimensions, statisticsWindow, statisticsPeriod)

  $stderr.puts "  - Number of elements #{metrics[:datapoints].count}" if $verbose
  $stderr.puts "  - Metrics: #{metrics}" if $debug
  
  if (metrics[:datapoints].count > 0)
    output = metrics[:datapoints][-1]
  else
    $stderr.puts "No data delivered from CloudWatch (probably no activity)" if $verbose
    output = {:average => 0, :minimum => 0, :maximum => 0, :sum => 0, :timestamp => "", :unit => 0}
  end
  

  reportValue = getCheckValue(statistics, output)
  
  #--- checking thresholds
  retCode=checkThresholds(reportValue, thresholdWarning, thresholdCritical)

  #--- output the header message
  $stderr.puts "  - Timestamp: #{Time.at(output[:timestamp])}" if $debug
  printf "#{retCode[:msg]} - Id: #{instance_id} #{metric}, Value: %.6f Unit: #{output[:unit]} (#{Time.at(output[:timestamp]).strftime("%Y-%m-%d %H:%M:%S %Z")})\n", reportValue
  #--- output nagios perfdata format

  printPerfdata(statistics, output)
      
else
  puts "OK - EC2 inctance #{instance_id} is not running."
  retCode[:value] = 0
end      

$stderr.puts "* Ret: #{retCode[:value].to_s}" if $verbose
exit retCode[:value]