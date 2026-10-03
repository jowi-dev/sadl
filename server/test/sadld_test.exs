defmodule SadldTest do
  use ExUnit.Case
  doctest Sadld

  test "greets the world" do
    assert Sadld.hello() == :world
  end
end
