module github.com/projectcalico/app-policy

go 1.15

require (
	github.com/docopt/docopt-go v0.0.0-20180111231733-ee0de3bc6815
	github.com/envoyproxy/go-control-plane v0.9.9-0.20210217033140-668b12f5399d
	github.com/gogo/protobuf v1.3.2
	github.com/kelseyhightower/envconfig v1.4.0 // indirect
	github.com/onsi/gomega v1.10.1
	github.com/projectcalico/libcalico-go v1.7.2-0.20210924170353-add0158bcc42
	github.com/sirupsen/logrus v1.6.0
	golang.org/x/net v0.0.0-20210520170846-37e1c6afe023
	google.golang.org/genproto v0.0.0-20210602131652-f16073e35f0c
	google.golang.org/grpc v1.38.0
	k8s.io/kube-openapi v0.0.0-20210817084001-7fbd8d59e5b8 // indirect
)

// Replace the envoy data-plane-api dependency with the projectcalico fork that includes the generated
// go bindings for the API. Upstream only includes the protobuf definitions, so we need to fork in order to
// supply the go code.
replace github.com/envoyproxy/data-plane-api => github.com/projectcalico/data-plane-api v0.0.0-20210121211707-a620ff3c8f7e
