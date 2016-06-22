defmodule ListPluginsCommandTest do
  use ExUnit.Case, async: false
  import TestHelper

  alias RabbitMQ.CLI.Plugins.Helpers, as: PluginHelpers

  @command RabbitMQ.CLI.Plugins.Commands.ListCommand
  @vhost "test1"
  @user "guest"
  @root   "/"
  @default_timeout :infinity


  #RABBITMQ_PLUGINS_DIR=~/dev/master/deps RABBITMQ_ENABLED_PLUGINS_FILE=/var/folders/cl/jnydxpf92rg76z05m12hlly80000gq/T/rabbitmq-test-instances/rabbit/enabled_plugins RABBITMQ_HOME=~/dev/master/deps/rabbit ./rabbitmq-plugins list_plugins

  setup_all do
    RabbitMQ.CLI.Distribution.start()
    node = get_rabbit_hostname
    :net_kernel.connect_node(node)
    {:ok, plugins_file} = :rabbit_misc.rpc_call(node,
                                                :application, :get_env,
                                                [:rabbit, :enabled_plugins_file])
    {:ok, plugins_dir} = :rabbit_misc.rpc_call(node,
                                               :application, :get_env,
                                               [:rabbit, :plugins_dir])
    {:ok, rabbitmq_home} = :rabbit_misc.rpc_call(node, :file, :get_cwd, [])

    :erlang.disconnect_node(node)
    :net_kernel.stop()

    {:ok, opts: %{enabled_plugins_file: plugins_file,
                  plugins_dir: plugins_dir,
                  rabbitmq_home: rabbitmq_home,
                  minimal: false, verbose: false,
                  enabled: false, implicitly_enabled: false}}
  end

  setup context do
    RabbitMQ.CLI.Distribution.start()
    :net_kernel.connect_node(get_rabbit_hostname)
    set_enabled_plugins(get_rabbit_hostname, 
                        [:rabbitmq_metronome, :rabbitmq_federation], 
                        context[:opts])

    on_exit([], fn ->
      :erlang.disconnect_node(get_rabbit_hostname)
      :net_kernel.stop()
    end)

    {
      :ok,
      opts: Map.merge(context[:opts], %{
              node: get_rabbit_hostname,
            })
    }
  end

  test "validate: specifying both --minimal and --verbose is reported as invalid", context do
    assert match?(
      {:validation_failure, {:bad_argument, _}},
      @command.validate([], Map.merge(context[:opts], %{minimal: true, verbose: true}))
    )
  end

  test "validate: specifying multiple patterns is reported as an error", context do
    assert @command.validate(["a", "b", "c"], context[:opts]) ==
      {:validation_failure, :too_many_args}
  end

  test "validate: specifying multiple patterns is reported as an error", context do
    assert @command.validate(["a", "b", "c"], context[:opts]) ==
      {:validation_failure, :too_many_args}
  end

  test "validate: not specifying enabled_plugins_file is reported as an error", context do
    assert @command.validate(["a"], Map.delete(context[:opts], :enabled_plugins_file)) ==
      {:validation_failure, :no_plugins_file}
  end

  test "validate: not specifying plugins_dir is reported as an error", context do
    assert @command.validate(["a"], Map.delete(context[:opts], :plugins_dir)) ==
      {:validation_failure, :no_plugins_dir}
  end


  test "validate: specifying non existent enabled_plugins_file is reported as an error", context do
    assert @command.validate(["a"], Map.merge(context[:opts], %{enabled_plugins_file: "none"})) ==
      {:validation_failure, :plugins_file_not_exists}
  end

  test "validate: specifying non existent plugins_dir is reported as an error", context do
    assert @command.validate(["a"], Map.merge(context[:opts], %{plugins_dir: "none"})) ==
      {:validation_failure, :plugins_dir_not_exists}
  end

  test "validate: failure to load rabbit application is reported as an error", context do
    assert {:validation_failure, {:unable_to_load_rabbit, _}} =
      @command.validate(["a"], Map.delete(context[:opts], :rabbitmq_home))
  end

  test "will report list of plugins from file for stopped node", context do
    node = context[:opts][:node]
    :ok = :rabbit_misc.rpc_call(node, :application, :stop, [:rabbitmq_metronome])
    on_exit(fn ->
      :rabbit_misc.rpc_call(node, :application, :start, [:rabbitmq_metronome])
    end)
    assert %{status: :node_down,
             plugins: [%{name: :amqp_client, enabled: :implicit, running: false}, 
                       %{name: :rabbitmq_federation, enabled: :enabled, running: false},
                       %{name: :rabbitmq_metronome, enabled: :enabled, running: false}]} =
           @command.run([".*"], Map.merge(context[:opts], %{node: :nonode}))
  end

  test "will report list of started plugins for started node", context do
    node = context[:opts][:node]
    :ok = :rabbit_misc.rpc_call(node, :application, :stop, [:rabbitmq_metronome])
    on_exit(fn ->
      :rabbit_misc.rpc_call(node, :application, :start, [:rabbitmq_metronome])
    end)
    assert %{status: :running,
             plugins: [%{name: :amqp_client, enabled: :implicit, running: true}, 
                       %{name: :rabbitmq_federation, enabled: :enabled, running: true},
                       %{name: :rabbitmq_metronome, enabled: :enabled, running: false}]} =
      @command.run([".*"], context[:opts])
  end

  test "will report description and dependencies for verbose mode", context do
    assert %{status: :running,
             plugins: [%{name: :amqp_client, enabled: :implicit, running: true, description: _, dependencies: []}, 
                       %{name: :rabbitmq_federation, enabled: :enabled, running: true, description: _, dependencies: [:amqp_client]},
                       %{name: :rabbitmq_metronome, enabled: :enabled, running: true, description: _, dependencies: [:amqp_client]}]} =
           @command.run([".*"], Map.merge(context[:opts], %{verbose: true}))
  end

  test "will repoer plugin names in minimal mode", context do
    assert %{status: :running,
             plugins: [:amqp_client, :rabbitmq_federation, :rabbitmq_metronome]} =
           @command.run([".*"], Map.merge(context[:opts], %{minimal: true}))
  end


  test "by default lists all plugins", context do
    set_enabled_plugins(context[:opts][:node], [:rabbitmq_federation], context[:opts])
    on_exit(fn ->
      set_enabled_plugins(context[:opts][:node], [:rabbitmq_metronome, :rabbitmq_federation], context[:opts])
    end)
    assert %{status: :running,
             plugins: [%{name: :amqp_client, enabled: :implicit, running: true}, 
                       %{name: :rabbitmq_federation, enabled: :enabled, running: true},
                       %{name: :rabbitmq_metronome, enabled: :not_enabled, running: false}]} =
           @command.run([".*"], context[:opts])
  end

  test "with enabled flag lists only explicitly enabled plugins", context do
    set_enabled_plugins(context[:opts][:node], [:rabbitmq_federation], context[:opts])
    on_exit(fn ->
      set_enabled_plugins(context[:opts][:node], [:rabbitmq_metronome, :rabbitmq_federation], context[:opts])
    end)
    assert %{status: :running,
             plugins: [%{name: :rabbitmq_federation, enabled: :enabled, running: true}]} =
           @command.run([".*"], Map.merge(context[:opts], %{enabled: true}))
  end

  test "with implicitly_enabled flag lists explicitly and implicitly enabled plugins", context do
    set_enabled_plugins(context[:opts][:node], [:rabbitmq_federation], context[:opts])
    on_exit(fn ->
      set_enabled_plugins(context[:opts][:node], [:rabbitmq_metronome, :rabbitmq_federation], context[:opts])
    end)
    assert %{status: :running,
             plugins: [%{name: :amqp_client, enabled: :implicit, running: true}, 
                       %{name: :rabbitmq_federation, enabled: :enabled, running: true}]} =
           @command.run([".*"], Map.merge(context[:opts], %{implicitly_enabled: true}))
  end


  def set_enabled_plugins(node, plugins, opts) do
    PluginHelpers.set_enabled_plugins(plugins, :online, node, opts)
  end

end
