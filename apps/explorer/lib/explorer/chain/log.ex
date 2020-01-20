defmodule Explorer.Chain.Log do
  @moduledoc "Captures a Web3 log entry generated by a transaction"

  use Explorer.Schema

  require Logger

  alias ABI.{Event, FunctionSelector}
  alias Explorer.Chain.{Address, Block, ContractMethod, Data, Hash, Transaction}
  alias Explorer.Repo

  # @required_attrs ~w(address_hash data index transaction_hash)a
  # @optional_attrs ~w(first_topic second_topic third_topic fourth_topic type block_number)a
  @required_attrs ~w(address_hash data index block_number block_hash)a
  @optional_attrs ~w(first_topic second_topic third_topic fourth_topic type transaction_hash)a

  @typedoc """
   * `address` - address of contract that generate the event
   * `block_hash` - hash of the block
   * `block_number` - The block number that the transfer took place.
   * `address_hash` - foreign key for `address`
   * `data` - non-indexed log parameters.
   * `first_topic` - `topics[0]`
   * `second_topic` - `topics[1]`
   * `third_topic` - `topics[2]`
   * `fourth_topic` - `topics[3]`
   * `transaction` - transaction for which `log` is
   * `transaction_hash` - foreign key for `transaction`.
   * `index` - index of the log entry in all logs for the `transaction`
   * `type` - type of event.  *Parity-only*
  """
  @type t :: %__MODULE__{
          address: %Ecto.Association.NotLoaded{} | Address.t(),
          address_hash: Hash.Address.t(),
          block_hash: Hash.Full.t(),
          block_number: non_neg_integer() | nil,
          data: Data.t(),
          first_topic: String.t(),
          second_topic: String.t(),
          third_topic: String.t(),
          fourth_topic: String.t(),
          transaction: %Ecto.Association.NotLoaded{} | Transaction.t(),
          transaction_hash: Hash.Full.t(),
          block: %Ecto.Association.NotLoaded{} | Block.t(),
          index: non_neg_integer(),
          type: String.t() | nil
        }

  @primary_key false
  schema "logs" do
    field(:data, Data)
    field(:first_topic, :string)
    field(:second_topic, :string)
    field(:third_topic, :string)
    field(:fourth_topic, :string)
    field(:block_number, :integer)
    field(:index, :integer, primary_key: true)
    field(:type, :string)

    timestamps()

    belongs_to(:address, Address, foreign_key: :address_hash, references: :hash, type: Hash.Address)

    belongs_to(:transaction, Transaction,
      foreign_key: :transaction_hash,
      primary_key: true,
      references: :hash,
      type: Hash.Full
    )

    belongs_to(:block, Block,
      foreign_key: :block_hash,
      primary_key: true,
      references: :hash,
      type: Hash.Full
    )
  end

  @doc """
  `address_hash` and `transaction_hash` are converted to `t:Explorer.Chain.Hash.t/0`.  The allowed values for `type`
  are currently unknown, so it is left as a `t:String.t/0`.

      iex> changeset = Explorer.Chain.Log.changeset(
      ...>   %Explorer.Chain.Log{},
      ...>   %{
      ...>     address_hash: "0x8bf38d4764929064f2d4d3a56520a76ab3df415b",
      ...>     block_hash: "0xf6b4b8c88df3ebd252ec476328334dc026cf66606a84fb769b3d3cbccc8471bd",
      ...>     data: "0x000000000000000000000000862d67cb0773ee3f8ce7ea89b328ffea861ab3ef",
      ...>     first_topic: "0x600bcf04a13e752d1e3670a5a9f1c21177ca2a93c6f5391d4f1298d098097c22",
      ...>     fourth_topic: nil,
      ...>     index: 0,
      ...>     second_topic: nil,
      ...>     third_topic: nil,
      ...>     transaction_hash: "0x53bd884872de3e488692881baeec262e7b95234d3965248c39fe992fffd433e5",
      ...>     type: "mined"
      ...>   }
      ...> )
      iex> changeset.valid?
      true
      iex> changeset.changes.address_hash
      %Explorer.Chain.Hash{
        byte_count: 20,
        bytes: <<139, 243, 141, 71, 100, 146, 144, 100, 242, 212, 211, 165, 101, 32, 167, 106, 179, 223, 65, 91>>
      }
      iex> changeset.changes.transaction_hash
      %Explorer.Chain.Hash{
        byte_count: 32,
        bytes: <<83, 189, 136, 72, 114, 222, 62, 72, 134, 146, 136, 27, 174, 236, 38, 46, 123, 149, 35, 77, 57, 101, 36,
                 140, 57, 254, 153, 47, 255, 212, 51, 229>>
      }
      iex> changeset.changes.type
      "mined"

  """
  def changeset(%__MODULE__{} = log, attrs \\ %{}) do
    log
    |> cast(attrs, @required_attrs)
    |> cast(attrs, @optional_attrs)
    |> validate_required(@required_attrs)
  end

  @doc """
  Decode transaction log data.
  """
  def decode(_log, %Transaction{to_address: nil}), do: {:error, :no_to_address}

  def decode(log, transaction = %Transaction{to_address: %{smart_contract: %{abi: abi}}}) when not is_nil(abi) do
    with {:ok, selector, mapping} <- find_and_decode(abi, log, transaction),
         identifier <- Base.encode16(selector.method_id, case: :lower),
         text <- function_call(selector.function, mapping),
         do: {:ok, identifier, text, mapping}
  end

  def decode(log, transaction) do
    case log.first_topic do
      "0x" <> hex_part ->
        case Integer.parse(hex_part, 16) do
          {number, ""} ->
            <<method_id::binary-size(4), _rest::binary>> = :binary.encode_unsigned(number)
            find_candidates(method_id, log, transaction)

          _ ->
            {:error, :could_not_decode}
        end

      _ ->
        {:error, :could_not_decode}
    end
  end

  defp find_candidates(method_id, log, transaction) do
    candidates_query =
      from(
        contract_method in ContractMethod,
        where: contract_method.identifier == ^method_id,
        limit: 3
      )

    candidates =
      candidates_query
      |> Repo.all()
      |> Enum.flat_map(fn contract_method ->
        case find_and_decode([contract_method.abi], log, transaction) do
          {:ok, selector, mapping} ->
            identifier = Base.encode16(selector.method_id, case: :lower)
            text = function_call(selector.function, mapping)

            [{:ok, identifier, text, mapping}]

          _ ->
            []
        end
      end)
      |> Enum.take(1)

    {:error, :contract_not_verified, candidates}
  end

  defp find_and_decode(abi, log, transaction) do
    with {%FunctionSelector{} = selector, mapping} <-
           abi
           |> ABI.parse_specification(include_events?: true)
           |> Event.find_and_decode(
             decode16!(log.first_topic),
             decode16!(log.second_topic),
             decode16!(log.third_topic),
             decode16!(log.fourth_topic),
             log.data.bytes
           ) do
      {:ok, selector, mapping}
    end
  rescue
    _ ->
      Logger.warn(fn -> ["Could not decode input data for log from transaction: ", Hash.to_iodata(transaction.hash)] end)

      {:error, :could_not_decode}
  end

  defp function_call(name, mapping) do
    text =
      mapping
      |> Stream.map(fn {name, type, indexed?, _value} ->
        indexed_keyword =
          if indexed? do
            ["indexed "]
          else
            []
          end

        [type, " ", indexed_keyword, name]
      end)
      |> Enum.intersperse(", ")

    IO.iodata_to_binary([name, "(", text, ")"])
  end

  def decode16!(nil), do: nil

  def decode16!(value) do
    value
    |> String.trim_leading("0x")
    |> Base.decode16!(case: :lower)
  end
end
