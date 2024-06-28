.PHONY: init plan apply destroy

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply -auto-approve

destroy:
	cd terraform && terraform destroy -auto-approve

build:
	docker build -f docker/Dockerfile.app -t app .

deploy: build
	./scripts/deploy.sh
