defmodule OpenChat.Media do
  @moduledoc false

  alias OpenChat.{Config, Errors}

  def persist_upload(%Plug.Upload{} = upload) do
    filename = safe_filename(upload.filename)
    mime = media_type(upload.content_type, filename)

    with {:ok, stat} <- File.stat(upload.path),
         :ok <- validate_size(stat.size),
         :ok <- validate_mime(mime),
         {:ok, stored_name} <- store(upload.path, filename) do
      {:ok,
       %{
         "extension" => stored_name |> Path.extname() |> String.trim_leading("."),
         "mimeType" => mime,
         "name" => filename,
         "size" => stat.size,
         "url" => media_url(stored_name)
       }}
    else
      {:error, %{"code" => _} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Errors.error("ERR_UPLOAD_FAILED", "Upload could not be stored.", %{
           "reason" => inspect(reason)
         })}
    end
  end

  def persist_upload(%{"path" => path, "filename" => filename} = upload) do
    persist_upload(%Plug.Upload{
      path: path,
      filename: filename,
      content_type: upload["content_type"] || upload["contentType"]
    })
  end

  def persist_upload(_other) do
    {:error, Errors.invalid("file", "Expected a multipart file upload.")}
  end

  def media_url(filename) do
    base = Application.get_env(:open_chat, :public_media_base_url)

    if blank?(base),
      do: "/media/#{URI.encode(filename)}",
      else: String.trim_trailing(base, "/") <> "/media/#{URI.encode(filename)}"
  end

  def stored_name?(filename) when is_binary(filename) do
    Regex.match?(~r/^[A-Za-z0-9_-]{8,}-[A-Za-z0-9._-]+$/, filename)
  end

  def stored_name?(_filename), do: false

  defp validate_size(size) do
    max = Config.upload_max_bytes()

    if size <= max do
      :ok
    else
      {:error,
       Errors.error("ERR_UPLOAD_TOO_LARGE", "Upload exceeds the configured size limit.", %{
         "maxBytes" => max,
         "size" => size
       })}
    end
  end

  defp validate_mime(mime) do
    allowed = Config.upload_allowed_mime_types()

    if mime in allowed do
      :ok
    else
      {:error,
       Errors.error("ERR_UPLOAD_TYPE_NOT_ALLOWED", "Upload media type is not allowed.", %{
         "mimeType" => mime,
         "allowedMimeTypes" => allowed
       })}
    end
  end

  defp store(path, filename) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(10), padding: false)
    stored_name = id <> "-" <> filename
    dest = Path.join(Config.upload_dir(), stored_name)

    with :ok <- File.mkdir_p(Config.upload_dir()),
         :ok <- File.cp(path, dest) do
      {:ok, stored_name}
    end
  end

  defp media_type(content_type, filename) do
    content_type
    |> to_s()
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> MIME.from_path(filename) || "application/octet-stream"
      type -> type
    end
  end

  defp safe_filename(filename) do
    filename
    |> to_s()
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim(".")
    |> case do
      "" -> "upload"
      name -> name
    end
  end

  defp blank?(value), do: value in [nil, "", false]
  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)
end
