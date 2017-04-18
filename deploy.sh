#!/usr/bin/env bash

# more bash-friendly output for jq
JQ="jq --raw-output --exit-status"

configure_aws_cli(){
	aws --version
	aws configure set default.region us-west-2
	aws configure set default.output json
}

deploy_cluster() {

    family="sample-webapp-task-family"

    make_task_def
    register_definition
    if [[ $(aws ecs update-service --cluster power-cluster --service sample-webapp-service --task-definition $revision | \
                   $JQ '.service.taskDefinition') != $revision ]]; then
        echo "Error updating service."
        return 1
    fi

	# find the task in the cluster that corresponds to the sample-webapp-service, and kill it so the below command doesn't stall
	for i in $(aws ecs list-tasks --cluster power-cluster | $JQ ".taskArns[$i]");
	do
	    if [[ $(aws ecs describe-tasks --cluster power-cluster --tasks $i | $JQ ".tasks[0].group") == "service:sample-webapp-service" ]]; then
	            # kill it
	            aws ecs stop-task --cluster power-cluster --task $i
	    fi
	done
	
    # wait for older revisions to disappear
    # not really necessary, but nice for demos
    for attempt in {1..30}; do
        if stale=$(aws ecs describe-services --cluster power-cluster --services sample-webapp-service | \
                       $JQ ".services[0].deployments | .[] | select(.taskDefinition != \"$revision\") | .taskDefinition"); then
            echo "Waiting for stale deployments:"
            echo "$stale"
            sleep 5
        else
            echo "Deployed!"
            return 0
        fi
    done
    echo "Service update took too long."
    return 1
}

make_task_def(){
	task_template='[
		{
			"name": "go-sample-webapp",
			"image": "%s.dkr.ecr.us-west-2.amazonaws.com/go-sample-webapp:%s",
			"essential": true,
			"memory": 200,
			"cpu": 10,
			"portMappings": [
				{
					"containerPort": 8080,
					"hostPort": 80
				}
			]
		}
	]'
	
	task_def=$(printf "$task_template" $AWS_ACCOUNT_ID $CIRCLE_SHA1)
}

push_ecr_image(){
	eval $(aws ecr get-login --region us-west-2)
	docker push $AWS_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/go-sample-webapp:$CIRCLE_SHA1
}

register_definition() {

    if revision=$(aws ecs register-task-definition --container-definitions "$task_def" --family $family | $JQ '.taskDefinition.taskDefinitionArn'); then
        echo "Revision: $revision"
    else
        echo "Failed to register task definition"
        return 1
    fi

}

configure_aws_cli
push_ecr_image
deploy_cluster
