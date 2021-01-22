module github.com/projectcalico/app-policy

go 1.12

require (
	github.com/docopt/docopt-go v0.0.0-20160216232012-784ddc588536
	github.com/envoyproxy/data-plane-api v0.0.0-20210121155913-ffd420ef8a9a
	github.com/gogo/googleapis v1.2.0
	github.com/gogo/protobuf v1.3.2
	github.com/kelseyhightower/envconfig v1.4.0 // indirect
	github.com/konsorten/go-windows-terminal-sequences v1.0.2 // indirect
	github.com/onsi/gomega v1.10.1
	github.com/projectcalico/libcalico-go v1.7.2-0.20210119213343-e868fb8ee2fb
	github.com/prometheus/client_golang v1.1.0 // indirect
	github.com/sirupsen/logrus v1.4.2
	golang.org/x/net v0.0.0-20201110031124-69a78807bb2b
	google.golang.org/grpc v1.27.0
)

// Replace the envoy data-plane-api dependency with the projectcalico fork that includes the generated
// go bindings for the API. Upstream only includes the protobuf definitions, so we need to fork in order to
// supply the go code.
replace github.com/envoyproxy/data-plane-api => github.com/projectcalico/data-plane-api v0.0.0-20210121211707-a620ff3c8f7e
