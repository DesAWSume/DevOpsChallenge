.PHONY: init install clean deploy test lint

all: init build deploy

init:
	git submodule update --recursive
	terraform init

build:	TechChallengeApp/.git
	docker build --build-arg arch=amd64 TechChallengeApp -t servian/techchallengeapp:latest

deploy:
	terraform apply -auto-approve

clean:
	terraform destroy -auto-approve
	rm -rf .terraform terraform.tfstate terraform.tfstate.backup